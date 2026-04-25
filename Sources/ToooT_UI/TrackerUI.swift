/*
 *  PROJECT ToooT (ToooT_UI)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 */

import SwiftUI
import MetalKit
import QuartzCore
import ToooT_Core
import ToooT_IO
import UniformTypeIdentifiers
import AVFoundation
import os.log
@preconcurrency import ScreenCaptureKit

private let uiLog = Logger(subsystem: "com.apple.ProjectToooT", category: "ToooT_UI")

public struct TrackerAppView: View {
    @State public var playbackState = PlaybackState()
    @State private var host: AudioHost?
    @State private var timeline: Timeline?
    public let documentURL: URL?
    public init(documentURL: URL? = nil) { self.documentURL = documentURL }

    @State private var showCommandPalette = false
    @State private var showCrashRecovery = false
    @State private var crashRecoveryAutosaves: [URL] = []

    public var body: some View {
        ZStack {
            StudioTheme.background.ignoresSafeArea()

            if playbackState.isDocumentLoaded {
                TrackerWorkspace(state: playbackState, host: host, timeline: timeline)
                    .transition(.opacity)
            } else {
                WelcomeOverlay()
            }

            // Global HUDs
            HUDOverlay(state: playbackState)

            if showCommandPalette {
                LegacyCommandPaletteShim(isPresented: $showCommandPalette, state: playbackState)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            setupEngine()
            checkForCrashRecovery()
        }
        .sheet(isPresented: $showCrashRecovery) {
            CrashRecoveryPromptView(
                isPresented: $showCrashRecovery,
                autosaves: crashRecoveryAutosaves,
                onRestore: { url in loadSong(from: url) },
                onDismiss: {})
        }
        .sheet(item: $playbackState.activePluginDialog) { pluginType in 
            PluginDialogContainer(state: playbackState, timeline: timeline, pluginType: pluginType) 
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LoadModFileURL"))) { n in 
            if let url = n.object as? URL { loadSong(from: url) } 
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LoadInstrumentFile"))) { notification in
            if let url = notification.object as? URL { handleInstrumentLoad(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TransportToggle"))) { _ in
            toggleTransport()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TransportStop"))) { _ in 
            timeline?.stop(); host?.stop() 
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NewTrackerDocument"))) { _ in 
            newDocument() 
        }
        .onKeyPress(keys: ["k"], phases: .down) { press in
            if press.modifiers.contains(.command) { showCommandPalette.toggle(); return .handled }
            return .ignored
        }
        .onKeyPress(keys: ["z"], phases: .down) { press in
            if press.modifiers.contains(.command) {
                if press.modifiers.contains(.shift) { playbackState.redo() }
                else { playbackState.undo() }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(keys: ["y"], phases: .down) { press in
            if press.modifiers.contains(.command) { playbackState.redo(); return .handled }
            return .ignored
        }
    }

    // MARK: - App Actions

    /// On launch, surface autosaves newer than the freshly-opened document. Skips the
    /// prompt when a documentURL is being loaded (the user picked a file — they don't
    /// want a recovery sheet over it) or when there's nothing recent to restore.
    private func checkForCrashRecovery() {
        guard documentURL == nil else { return }
        let recent = AudioHost.recentAutosaves(maxAgeSeconds: 24 * 3600)
        guard !recent.isEmpty else { return }
        crashRecoveryAutosaves = recent
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            showCrashRecovery = true
        }
    }

    private func setupEngine() {
        guard host == nil else { return }
        let h = AudioHost()
        self.host = h
        Task { @MainActor in
            try? await h.setup()
            if let engine = h.trackerAU {
                let tl = Timeline(state: playbackState, engine: engine, renderNode: h.renderNode)
                tl.onBPMChange = { [weak h] bpm in h?.updateClockBPM(bpm) }
                tl.onAutosaveTick = { [weak h, weak playbackState] in
                    guard let h, let playbackState else { return }
                    h.autosave(state: playbackState)
                }
                // Wire PlaybackState → engine bus/send arrays so mixer UI can set sends
                // without reaching through AudioEngine.renderNode.resources.
                playbackState.engineRenderResources = engine.renderNode.resources
                self.timeline = tl
                if let url = documentURL { loadSong(from: url) }
            }
        }
    }

    private func toggleTransport() {
        if playbackState.isPlaying { timeline?.stop(); host?.stop() }
        else { try? host?.start(bpm: playbackState.bpm); timeline?.play() }
    }

    private func handleInstrumentLoad(_ url: URL) {
        Task { @MainActor in
            guard let engine = timeline?.audioEngine else {
                playbackState.showStatus("Cannot load sample: audio engine not ready")
                return
            }
            let instID = playbackState.selectedInstrument
            let offset = playbackState.instruments.values.reduce(0) { max($0, $1.regionCount > 0 ? $1.regions.0.offset + $1.regions.0.length : 0) }
            do {
                try await engine.sampleBank.load(from: url, offset: offset)
                var newInst = playbackState.instruments[instID] ?? Instrument()
                newInst.nameString = url.lastPathComponent
                let file = try AVAudioFile(forReading: url)
                newInst.setSingleRegion(SampleRegion(offset: offset, length: Int(file.length), isStereo: file.fileFormat.channelCount > 1))
                playbackState.instruments[instID] = newInst
                timeline?.publishSnapshot()
                playbackState.textureInvalidationTrigger += 1
            } catch { uiLog.error("Failed to load instrument: \(error)") }
        }
    }

    private func newDocument() {
        let oldEvents = playbackState.sequencerData.events
        let newEvents: UnsafeMutablePointer<TrackerEvent> = .allocate(capacity: kMaxChannels * 64 * 100)
        newEvents.initialize(repeating: .empty, count: kMaxChannels * 64 * 100)
        playbackState.sequencerData.events = newEvents
        timeline?.renderNode?.queueRawDeallocation(oldEvents)
        
        playbackState.instruments = [:]; playbackState.orderList = [0]; playbackState.songLength = 1; playbackState.documentURL = nil
        playbackState.bpm = 125; playbackState.ticksPerRow = 6; playbackState.textureInvalidationTrigger += 1
        playbackState.songTitle = "Untitled Project"; playbackState.isDocumentLoaded = true
        playbackState.activeTab = .patterns
        timeline?.stop(); timeline?.publishSnapshot(); playbackState.showStatus("New Project Ready")
    }

    private func loadSong(from url: URL) {
        Task { @MainActor in
            guard let activeTimeline = self.timeline else {
                playbackState.showStatus("Load failed: audio engine not ready — press Start Audio Engine first")
                return
            }
            do {
                let ext = url.pathExtension.lowercased()
                if ext == "xm" || ext == "it" || ext == "s3m" {
                    try await loadTrackerFormat(url: url, ext: ext, timeline: activeTimeline)
                    return
                }

                let parser = MADParser(sourceURL: url)
                if let (madSlab, madInsts, loadedPluginStates) = try parser.parse(sampleBank: activeTimeline.audioEngine?.sampleBank) {
                    let oldEvents = self.playbackState.sequencerData.events
                    self.playbackState.sequencerData.events = madSlab
                    activeTimeline.renderNode?.queueRawDeallocation(oldEvents)
                    self.playbackState.instruments = madInsts
                    self.playbackState.pluginStates = loadedPluginStates
                    self.host?.setPluginStates(loadedPluginStates)
                    self.playbackState.isDocumentLoaded = true
                    self.playbackState.activeTab = .patterns
                    
                    // Reset transport state for new song
                    activeTimeline.stop()
                    self.playbackState.currentOrder = 0
                    self.playbackState.currentPattern = 0
                    self.playbackState.currentEngineRow = 0
                    self.playbackState.currentUIRow = 0
                    self.playbackState.fractionalRow = 0
                    
                    activeTimeline.publishSnapshot()
                    playbackState.showStatus("Loaded \(madInsts.count) instruments from \(url.lastPathComponent)")
                } else {
                    playbackState.showStatus("Load failed: \(url.lastPathComponent) is not a recognised MAD or MOD file")
                }
            } catch {
                playbackState.showStatus("Load failed: \(error.localizedDescription)")
            }
        }
    }

    private func loadTrackerFormat(url: URL, ext: String, timeline: Timeline) async throws {
        let transpiler = FormatTranspiler(sourceURL: url)
        let snapshotEvents = try transpiler.createSnapshot(from: url)
        let instMap = transpiler.parseInstruments(from: url)
        let meta = transpiler.parseMetadata(from: url)

        // Copy [TrackerEvent] array into the raw slab the engine expects
        let capacity = kMaxChannels * 64 * 100
        let newSlab: UnsafeMutablePointer<TrackerEvent> = .allocate(capacity: capacity)
        newSlab.initialize(repeating: .empty, count: capacity)
        let copyCount = min(snapshotEvents.count, capacity)
        for i in 0..<copyCount { newSlab[i] = snapshotEvents[i] }

        let oldEvents = self.playbackState.sequencerData.events
        self.playbackState.sequencerData.events = newSlab
        timeline.renderNode?.queueRawDeallocation(oldEvents)

        if let bank = timeline.audioEngine?.sampleBank {
            try transpiler.loadSamples(from: url, intoBank: bank)
        }

        self.playbackState.instruments = instMap
        self.playbackState.orderList = meta.orderList
        self.playbackState.songLength = meta.songLength
        self.playbackState.pluginStates = [:]
        self.playbackState.isDocumentLoaded = true
        self.playbackState.activeTab = .patterns
        
        timeline.stop()
        self.playbackState.currentOrder = 0
        self.playbackState.currentPattern = 0
        self.playbackState.currentEngineRow = 0
        self.playbackState.currentUIRow = 0
        self.playbackState.fractionalRow = 0

        timeline.publishSnapshot()
        playbackState.showStatus("Loaded \(instMap.count) instruments from \(url.lastPathComponent) [\(ext.uppercased())]")
    }
}

struct HUDOverlay: View {
    let state: PlaybackState
    var body: some View {
        VStack {
            if let msg = state.statusMessage {
                Text(msg)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.black.opacity(0.8))
                    .foregroundColor(.green)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.5), lineWidth: 1))
                    .padding(.top, 60)
            }
            Spacer()
        }
    }
}

struct WelcomeOverlay: View {
    var body: some View {
        ZStack {
            StudioTheme.surface.opacity(0.95).ignoresSafeArea()
            VStack(spacing: 30) {
                Image(systemName: "music.quarternote.3").font(.system(size: 80)).foregroundStyle(StudioTheme.gradient)
                Text("PROJECT ToooT").font(.system(size: 40, weight: .black, design: .monospaced)).foregroundStyle(StudioTheme.gradient)
                Text("Mac Tracker for the Post-Human Era").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(.gray)
                
                HStack(spacing: 20) {
                    WelcomeButton(label: "NEW PROJECT", systemImage: "plus.square.fill", color: .blue) { NotificationCenter.default.post(name: NSNotification.Name("NewTrackerDocument"), object: nil) }
                    WelcomeButton(label: "LOAD MOD/MAD/XM", systemImage: "folder.fill", color: .green) { 
                        let p = NSOpenPanel()
                        p.allowedContentTypes = [
                            UTType(filenameExtension: "mod")!,
                            UTType(filenameExtension: "mad")!,
                            UTType(filenameExtension: "madk")!,
                            UTType(filenameExtension: "madg")!,
                            UTType(filenameExtension: "xm")!,
                            UTType(filenameExtension: "it")!,
                            UTType(filenameExtension: "s3m")!
                        ]
                        if p.runModal() == .OK, let url = p.url { NotificationCenter.default.post(name: NSNotification.Name("LoadModFileURL"), object: url) } 
                    }
                }
                
                Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NewTrackerDocument"), object: nil) }) {
                    Label("START AUDIO ENGINE", systemImage: "power").font(.system(size: 10, weight: .black)).padding(10)
                }.buttonStyle(.borderedProminent).tint(.orange)
            }
        }
    }
}

struct WelcomeButton: View {
    let label: String; let systemImage: String; let color: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage).font(.title)
                Text(label).font(.system(size: 10, weight: .black))
            }
            .frame(width: 120, height: 100)
            .background(color.opacity(0.2))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.5), lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

// CommandPaletteView lives in CommandPalette.swift. This shim preserves the
// (isPresented:state:) call signature from earlier callers.
struct LegacyCommandPaletteShim: View {
    @Binding var isPresented: Bool
    let state: PlaybackState
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { isPresented = false }
            CommandPaletteView()
                .onKeyPress(.escape) { isPresented = false; return .handled }
        }.zIndex(100)
    }
}
