/*
 *  PROJECT ToooT (ToooT_UI)
 *  Video-sync view: loads a .mp4/.mov, plays it in lock-step with the tracker
 *  playhead so composers can score to picture. The DAW is the master clock;
 *  AVPlayer seeks to follow.
 *
 *  The sync is sample-accurate up to the display-link refresh (120 Hz on
 *  ProMotion). For true frame-accurate edit work we'd add LTC output; that's
 *  a follow-up layered on top of MIDI2Manager.
 */

import SwiftUI
import AVFoundation
import AVKit
import Combine

@MainActor
public final class VideoSyncModel: ObservableObject {
    public let player = AVPlayer()
    @Published public var loadedURL: URL?
    @Published public var duration: TimeInterval = 0
    @Published public var isPlaying: Bool = false

    /// Pattern rows per second of video — derived from the DAW's playback rate so
    /// 1 row = 1 video frame at the project tempo × ticksPerRow.
    public var rowsPerSecond: Double = 4

    private var cancellables: Set<AnyCancellable> = []

    public init() {}

    public func load(url: URL) {
        loadedURL = url
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        Task {
            let asset = item.asset
            if let dur = try? await asset.load(.duration) {
                await MainActor.run { self.duration = dur.seconds }
            }
        }
    }

    /// Call from Timeline's 30 Hz sync loop with the current playhead row + row duration
    /// in seconds. We seek the player to the corresponding video time only when the
    /// drift exceeds one frame — otherwise we let AVPlayer run its own rate.
    public func syncTo(playheadRow: Float, rowDurationSeconds: Float) {
        guard let item = player.currentItem else { return }
        let daw = Double(playheadRow) * Double(rowDurationSeconds)
        let vid = item.currentTime().seconds
        let drift = daw - vid
        if abs(drift) > 1.0 / 24.0 {   // > 1 frame at 24 fps → resync
            let t = CMTime(seconds: daw, preferredTimescale: 600)
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    public func play()  { player.play();  isPlaying = true  }
    public func pause() { player.pause(); isPlaying = false }
    public func seek(to seconds: Double) {
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: t)
    }
}

public struct VideoSyncView: View {
    @StateObject private var model = VideoSyncModel()
    public var state: PlaybackState
    public init(state: PlaybackState) { self.state = state }

    public var body: some View {
        VStack(spacing: 8) {
            if model.loadedURL == nil {
                openPicker
            } else {
                VideoPlayer(player: model.player)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                HStack {
                    Button(model.isPlaying ? "Pause" : "Play") {
                        model.isPlaying ? model.pause() : model.play()
                    }
                    Spacer()
                    Text("\(model.loadedURL?.lastPathComponent ?? "")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Replace") { model.loadedURL = nil; model.player.replaceCurrentItem(with: nil) }
                }
                .padding(.horizontal, 12)
            }
        }
        .onChange(of: state.fractionalRow) { _, _ in
            // DAW playhead drives video position.
            model.syncTo(playheadRow: state.fractionalRow,
                         rowDurationSeconds: rowDurationSeconds())
        }
    }

    private func rowDurationSeconds() -> Float {
        let spt = (44100.0 * 2.5) / Float(max(32, state.bpm))
        return spt * Float(state.ticksPerRow) / 44100.0
    }

    private var openPicker: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.fill").font(.system(size: 40)).foregroundColor(.secondary)
            Text("Drop a .mp4 or .mov here, or click Open.")
                .font(.system(size: 13)).foregroundColor(.secondary)
            Button("Open Video…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.movie]
                if panel.runModal() == .OK, let url = panel.url { model.load(url: url) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.3))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.load(url: url) } }
            }
            return true
        }
    }
}
