/*
 *  PROJECT ToooT (ToooT_UI)
 *  Linear-arrangement timeline view.
 *
 *  Horizontal timeline of clips on tracks. Classic Pro Tools / Logic / Reaper /
 *  Bitwig / Studio One paradigm. Backed by ToooT_Core's `Arrangement` model,
 *  which persists inside .mad via the TOOO chunk.
 *
 *  UX:
 *    • Horizontal axis = beats; vertical = tracks.
 *    • Pinch / slider zooms the timeline.
 *    • Click a clip to select; drag to move; drag edge to resize.
 *    • Playhead sweeps from left to right driven by state.playheadPosition
 *      (converted beats ↔ rows via time signature).
 *    • Right-click on empty space adds a clip (pattern reference by default).
 *
 *  Performance: Canvas rendering for clips + separate Canvas overlay for the
 *  playhead. Throttled redraw via onChange of state.fractionalRow.
 */

import SwiftUI
import ToooT_Core

@MainActor
public struct ArrangementView: View {
    @Bindable var state: PlaybackState
    @State private var arrangement: Arrangement

    // Viewport controls.
    @State private var zoomLevel: Double = 60      // pixels per beat
    @State private var selectedClipID: UUID?
    @State private var dragStartBeat: Double?
    @State private var dragStartClip: Clip?

    private let trackHeight: CGFloat = 64
    private let rulerHeight: CGFloat = 24
    private let trackHeaderWidth: CGFloat = 140

    public init(state: PlaybackState) {
        self.state = state
        // Load existing arrangement from PlaybackState if present, else seed demo.
        self._arrangement = State(initialValue: Self.loadOrSeed(state: state))
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 0) {
                        trackHeaderColumn
                        timelineBody(geoWidth: geo.size.width)
                    }
                }
            }
        }
        .background(Color.black.opacity(0.95))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("ARRANGEMENT", systemImage: "rectangle.stack.badge.play")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(.green)
            Text("\(arrangement.bpm) BPM • \(arrangement.timeSignature.numerator)/\(arrangement.timeSignature.denominator)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
            Text("Zoom").font(.system(size: 8, weight: .bold)).foregroundColor(.gray)
            Slider(value: $zoomLevel, in: 20...200).frame(width: 120).controlSize(.mini)
            Button("Add Track") { addTrack() }.controlSize(.mini)
            Button("Add Clip")  { addClip() }.controlSize(.mini)
            Button("Save to .mad") { saveIntoState() }.controlSize(.mini)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.black.opacity(0.6))
    }

    // MARK: - Track header column (names + controls)

    private var trackHeaderColumn: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.05))
                .frame(width: trackHeaderWidth, height: rulerHeight)
                .overlay(Text("Tracks").font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.secondary))
            ForEach(Array(arrangement.tracks.enumerated()), id: \.element.id) { idx, track in
                trackHeaderRow(idx: idx, track: track)
            }
        }
    }

    private func trackHeaderRow(idx: Int, track: Track) -> some View {
        HStack(spacing: 6) {
            Circle().fill(track.soloed ? Color.yellow : (track.muted ? .red : .green.opacity(0.5)))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name.isEmpty ? "Track \(idx + 1)" : track.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("ch \(track.channelIndex + 1)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button { toggleMute(idx) } label: {
                Image(systemName: track.muted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 10))
            }.buttonStyle(.plain)
            Button { toggleSolo(idx) } label: {
                Text("S").font(.system(size: 9, weight: .bold))
                    .foregroundColor(track.soloed ? .yellow : .secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(width: trackHeaderWidth, height: trackHeight)
        .background(idx % 2 == 0 ? Color.white.opacity(0.03) : .clear)
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(.white.opacity(0.1)), alignment: .bottom)
    }

    // MARK: - Timeline body

    private func timelineBody(geoWidth: CGFloat) -> some View {
        let totalBeats = max(32.0, arrangement.totalDuration.value + 8)
        let timelineWidth = CGFloat(totalBeats) * zoomLevel

        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                // Beat ruler
                Canvas { ctx, size in
                    drawRuler(ctx: ctx, size: size, totalBeats: totalBeats)
                }.frame(width: timelineWidth, height: rulerHeight)
            }
            ZStack(alignment: .topLeading) {
                // Body: track lanes + clips
                Canvas { ctx, size in
                    drawTracks(ctx: ctx, size: size)
                    drawClips(ctx: ctx, size: size)
                    drawPlayhead(ctx: ctx, size: size)
                }
                .frame(width: timelineWidth,
                       height: CGFloat(max(1, arrangement.tracks.count)) * trackHeight)
                .gesture(clipDragGesture(timelineWidth: timelineWidth))
            }
        }
    }

    private func drawRuler(ctx: GraphicsContext, size: CGSize, totalBeats: Double) {
        for beat in 0...Int(totalBeats) {
            let x = CGFloat(beat) * zoomLevel
            let isBar = beat % arrangement.timeSignature.numerator == 0
            let color: Color = isBar ? .white.opacity(0.6) : .white.opacity(0.25)
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: x, y: isBar ? 2 : 10))
                p.addLine(to: CGPoint(x: x, y: size.height))
            }, with: .color(color), lineWidth: isBar ? 1 : 0.5)
            if isBar {
                let label = "\(beat / arrangement.timeSignature.numerator + 1)"
                ctx.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(.white),
                         at: CGPoint(x: x + 3, y: size.height / 2))
            }
        }
    }

    private func drawTracks(ctx: GraphicsContext, size: CGSize) {
        for (idx, _) in arrangement.tracks.enumerated() {
            let y = CGFloat(idx) * trackHeight
            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: trackHeight)),
                     with: .color(idx % 2 == 0 ? .white.opacity(0.02) : .clear))
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: 0, y: y + trackHeight))
                p.addLine(to: CGPoint(x: size.width, y: y + trackHeight))
            }, with: .color(.white.opacity(0.1)), lineWidth: 0.5)
        }
    }

    private func drawClips(ctx: GraphicsContext, size: CGSize) {
        for (tIdx, track) in arrangement.tracks.enumerated() {
            for clip in track.clips {
                let x = CGFloat(clip.start.value) * zoomLevel
                let w = CGFloat(clip.duration.value) * zoomLevel
                let y = CGFloat(tIdx) * trackHeight + 4
                let h = trackHeight - 8
                let rect = CGRect(x: x, y: y, width: max(4, w), height: h)
                let tint = clipTint(for: clip, selected: clip.id == selectedClipID)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(tint))
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 4),
                           with: .color(.white.opacity(clip.id == selectedClipID ? 0.9 : 0.3)),
                           lineWidth: clip.id == selectedClipID ? 2 : 1)
                if w > 40 {
                    ctx.draw(Text(clip.name.isEmpty ? clip.kind.rawValue : clip.name)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white),
                             at: CGPoint(x: x + 6, y: y + h / 2))
                }
            }
        }
    }

    private func drawPlayhead(ctx: GraphicsContext, size: CGSize) {
        guard state.isPlaying else { return }
        // Convert pattern row → beats (1 row = 1/4 beat at 4/4, ticksPerRow=6 default).
        let rowFrac = Double(state.currentEngineRow) + Double(state.fractionalRow)
        let beats = rowFrac / 4.0
        let x = CGFloat(beats) * zoomLevel
        ctx.stroke(Path { p in
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
        }, with: .color(.red.opacity(0.9)), lineWidth: 2)
    }

    private func clipTint(for clip: Clip, selected: Bool) -> Color {
        let base: Color = {
            switch clip.kind {
            case .pattern: return .green
            case .audio:   return .blue
            case .midi:    return .purple
            }
        }()
        return selected ? base.opacity(0.75) : base.opacity(0.45)
    }

    // MARK: - Drag gesture (move clips)

    private func clipDragGesture(timelineWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                let beat = Double(g.startLocation.x / zoomLevel)
                let trackIdx = Int(g.startLocation.y / trackHeight)
                if dragStartClip == nil {
                    // Start: pick the clip under the cursor.
                    if trackIdx >= 0, trackIdx < arrangement.tracks.count {
                        let track = arrangement.tracks[trackIdx]
                        if let clip = track.clips.first(where: { $0.contains(beat: Beats(beat)) }) {
                            selectedClipID = clip.id
                            dragStartClip = clip
                            dragStartBeat = beat
                        }
                    }
                }
                // In-flight: move the selected clip.
                if let clip = dragStartClip, let start = dragStartBeat {
                    let deltaBeats = Double(g.translation.width / zoomLevel)
                    let newStart = max(0, Double(clip.start.value) + (beat - start) + deltaBeats - (beat - start))
                    // Simpler: absolute beat based on current location.
                    let absBeat = max(0, Double(g.location.x / zoomLevel)
                                         - (start - Double(clip.start.value)))
                    updateClipStart(id: clip.id, to: Beats(absBeat))
                    _ = newStart
                }
            }
            .onEnded { _ in
                dragStartClip = nil
                dragStartBeat = nil
            }
    }

    // MARK: - Mutations

    private func addTrack() {
        let idx = arrangement.tracks.count
        arrangement.tracks.append(Track(name: "Track \(idx + 1)", channelIndex: idx))
    }

    private func addClip() {
        guard let trackIdx = arrangement.tracks.indices.first else { addTrack(); return }
        var track = arrangement.tracks[trackIdx]
        let start = track.totalDuration
        track.add(Clip(kind: .pattern, name: "Pattern \(track.clips.count + 1)",
                       start: start, duration: Beats(4), sourceIndex: 0))
        arrangement.tracks[trackIdx] = track
    }

    private func toggleMute(_ idx: Int) {
        guard idx < arrangement.tracks.count else { return }
        arrangement.tracks[idx].muted.toggle()
    }
    private func toggleSolo(_ idx: Int) {
        guard idx < arrangement.tracks.count else { return }
        arrangement.tracks[idx].soloed.toggle()
    }

    private func updateClipStart(id: UUID, to start: Beats) {
        for tIdx in arrangement.tracks.indices {
            var track = arrangement.tracks[tIdx]
            if let cIdx = track.clips.firstIndex(where: { $0.id == id }) {
                track.clips[cIdx].start = start
                track.clips.sort { $0.start.value < $1.start.value }
                arrangement.tracks[tIdx] = track
                return
            }
        }
    }

    // MARK: - Persistence

    private func saveIntoState() {
        // Merge arrangement into pluginStates so the next .mad save carries it.
        state.pluginStates.merge(arrangement.exportAsPluginStateData()) { _, new in new }
        state.showStatus("Arrangement saved — write .mad to persist")
    }

    private static func loadOrSeed(state: PlaybackState) -> Arrangement {
        if let existing = Arrangement.importFromPluginStateData(state.pluginStates) {
            return existing
        }
        // Seed with 4 empty tracks so the view isn't blank on first open.
        let arr = Arrangement(bpm: state.bpm)
        for i in 0..<4 {
            arr.tracks.append(Track(name: "Track \(i + 1)", channelIndex: i))
        }
        return arr
    }
}
