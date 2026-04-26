/*
 *  PROJECT ToooT (ToooT_UI)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 */

import SwiftUI
import ToooT_Core
import AVFoundation

public struct HostedPlugin: Identifiable, @unchecked Sendable {
    public let id = UUID(); public let name: String; public let component: AudioComponentDescription; public var au: AUAudioUnit?
}

public final class SequencerData: @unchecked Sendable {
    public var events: UnsafeMutablePointer<TrackerEvent>
    public init() { self.events = .allocate(capacity: kMaxChannels * 64 * 100); self.events.initialize(repeating: .empty, count: kMaxChannels * 64 * 100) }
    deinit { events.deallocate() }
}

@MainActor @Observable
public final class PlaybackState: @unchecked Sendable {
    public var isPlaying: Bool = false
    public var currentOrder: Int = 0
    public var currentPattern: Int = 0
    public var currentEngineRow: Int = 0
    public var currentUIRow: Int = 0
    public var fractionalRow: Float = 0.0
    public var orderList: [Int] = [0]
    public var songLength: Int = 1
    
    public var selectedChannel: Int = 0
    public var selectedRow: Int = 0
    public var cursorX: Int = 0; public var cursorY: Int = 0; public var cursorCol: Int = 0 
    
    public var selectedInstrument: Int = 1
    public var activeTab: WorkbenchTab = .dashboard
    public enum InspectorMode { case instrument, channel, browser }; public var inspectorMode: InspectorMode = .instrument
    public func selectInstrument(_ id: Int) { selectedInstrument = id; inspectorMode = .instrument }
    public func selectChannel(_ id: Int) { selectedChannel = id; inspectorMode = .channel }
    
    public var browserPath: URL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "/")
    
    public var horizontalScrollX: Float = 0.0; public var xZoom: CGFloat = 1.0; public var draggedPointIndex: Int? = nil
    public var instruments: [Int: Instrument] = [:] { didSet { for (id, inst) in instruments { if id >= 0 && id < 256 { instrumentBank[id] = inst } } } }
    public var sequencerData = SequencerData()
    nonisolated(unsafe) public let instrumentBank: UnsafeMutablePointer<Instrument>
    
    public var peakLevel: Float = 0.0; public var activeVoices: Int = 0; public var algSeed: UInt32 = 0
    public var isRecording: Bool = false; public var recordedSamplesL: [Float] = []; public var recordedSamplesR: [Float] = []
    /// Per-channel take stacks. Each `TakeLane` owns the recorded passes
    /// for one channel. Replace mode clears the lane on each new record;
    /// overdub mode appends. Loop mode appends one take per loop pass.
    public var takeLanes: [Int: TakeLane] = [:]
    /// Mode for the next `startRecording` call. Defaults to .replace —
    /// the legacy behavior. Overdub leaves prior takes intact and stacks
    /// the new one on top.
    public var recordingMode: RecordingMode = .replace
    /// Channel whose take stack the next recording lands in. -1 means
    /// "no channel — just capture into recordedSamplesL/R as before".
    public var recordingChannel: Int = -1
    
    public var masterVolume: Double = 0.8; public var isStereoWideEnabled: Bool = false; public var isReverbEnabled: Bool = false; public var isMasterEQEnabled: Bool = false
    /// 10 master-EQ band gains in dB (0 = flat). Bands: 31/62/125/250/500/1k/2k/4k/8k/16k Hz.
    public var masterEQBandsDB: [Float] = Array(repeating: 0, count: 10)
    public var isMetronomeEnabled: Bool = false; public var isMasterLimiterEnabled: Bool = true
    public var sidechainChannel: Int = -1; public var sidechainAmount: Float = 0.0
    public var bpm: Int = 125; public var ticksPerRow: Int = 6; public var activeTier: SynthesisTier = .studio

    /// Studio tier — clean / classic. Two knobs:
    ///   • corruption: 0 = pristine, 1 = signal noise / data drops
    ///   • glitchRate: 0 = stable, 1 = frequent random retriggers
    public var studioCorruption: Float = 0.0
    public var studioGlitchRate: Float = 0.0
    /// Organic tier — humanized.
    ///   • timingDrift: micro-timing variance per voice
    ///   • breathiness: throat-resonance amount on sustained notes
    public var organicTimingDrift: Float = 0.0
    public var organicBreathiness: Float = 0.0
    /// Generative tier — experimental.
    ///   • fractalDim: 1 = octave doubling, 2 = chaotic
    ///   • voidThreshold: probability of unexpected silence / artifacts
    public var generativeFractalDim: Float = 1.0
    public var generativeVoidThreshold: Float = 0.5
    
    public var channelVolumes: [Float] { (0..<kMaxChannels).map { channelVolumesPtr[$0] } }
    
    public var isDocumentLoaded: Bool = false; public var documentURL: URL? = nil; public var songTitle: String = "Untitled Song"
    
    nonisolated(unsafe) public let channelVolumesPtr: UnsafeMutablePointer<Float>
    nonisolated(unsafe) public let channelPansPtr:    UnsafeMutablePointer<Float>
    nonisolated(unsafe) public let channelMutesPtr:   UnsafeMutablePointer<Int32>
    nonisolated(unsafe) public let channelSolosPtr:   UnsafeMutablePointer<Int32>
    nonisolated(unsafe) public let midiChannelsPtr:   UnsafeMutablePointer<Int32>
    nonisolated(unsafe) public let volEnvEnabledPtr:   UnsafeMutablePointer<Int32>
    nonisolated(unsafe) public let panEnvEnabledPtr:   UnsafeMutablePointer<Int32>
    nonisolated(unsafe) public let pitchEnvEnabledPtr: UnsafeMutablePointer<Int32>

    private var undoStack: [[TrackerEvent]] = []; private var redoStack: [[TrackerEvent]] = []
    /// Parallel array to undoStack — same length, holds a human-readable label for each
    /// snapshot (e.g. "Paint note", "Fill channel 3", "Shuffle", "Humanize"). The Undo
    /// History Browser surfaces these so the user can jump back N steps meaningfully.
    public private(set) var undoLabels: [String] = []
    public var textureInvalidationTrigger: Int = 0; public var mixerGeneration: Int = 0; public var activePluginDialog: PluginType? = nil; public var statusMessage: String? = nil

    // MARK: - Non-Destructive Offline DSP undo
    /// Snapshot of PCM data captured before the last OfflineDSP operation.
    public var dspUndoBuffer: [Float]? = nil
    public var dspUndoOffset: Int = 0
    public var dspUndoInstrument: Int = 0
    public var canUndoDSP: Bool { dspUndoBuffer != nil }

    public func snapshotDSPUndo(bank: UnifiedSampleBank, offset: Int, length: Int, instrument: Int) {
        guard length > 0 else { return }
        let ptr = bank.samplePointer.advanced(by: offset)
        dspUndoBuffer = Array(UnsafeBufferPointer(start: ptr, count: length))
        dspUndoOffset = offset
        dspUndoInstrument = instrument
    }

    public func restoreDSPUndo(bank: UnifiedSampleBank) {
        guard let buf = dspUndoBuffer else { return }
        buf.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            memcpy(bank.samplePointer.advanced(by: dspUndoOffset), base, buf.count * MemoryLayout<Float>.size)
        }
        dspUndoBuffer = nil
        textureInvalidationTrigger += 1
    }

    // MARK: - AUv3 Plugin State Persistence (keyed by PluginType.rawValue → JSON Data)
    public var pluginStates: [String: Data] = [:]

    /// Per-project scene bank. Scenes are saved into the .mad TOOO chunk alongside
    /// plugin states (SceneBank.exportAsPluginStateData is merged into pluginStates
    /// at save time; imported on load).
    public let sceneBank = SceneBank()

    /// Markers + time-signature changes. Persisted alongside scenes in the
    /// `.mad` `TOOO` chunk. Render-path consumption of time-sig changes is
    /// not yet wired (mid-song meter changes affect bar boundaries
    /// non-trivially); markers are seek targets.
    public let timingMap = TimingMap()

    /// Seeks the playhead to a named marker. No-op if the marker is missing.
    /// Tracker convention: 4 rows per beat → row = beat * 4, with order
    /// derived as row / 64.
    public func seekToMarker(named name: String) {
        guard let m = timingMap.marker(named: name) else { return }
        let absRow = Int((m.beat * 4.0).rounded())
        currentOrder = max(0, min(songLength - 1, absRow / 64))
        currentEngineRow = absRow % 64
        currentUIRow = currentEngineRow
        fractionalRow = 0
    }

    /// CC-lane storage keyed by "pat.<pattern>.ch.<channel>.cc.<cc>" → [col:value].
    /// Persists through the `.mad` TOOO chunk via `pluginStates` merge at save time.
    /// Values are 0…1 normalized (translated to MIDI 0–127 on output).
    public var ccLanes: [String: [Int: Float]] = [:]

    public func ccLaneValue(pattern p: Int, ch: Int, col: Int, cc: Int) -> Float {
        ccLanes["pat.\(p).ch.\(ch).cc.\(cc)"]?[col] ?? 0
    }
    public func setCCLaneValue(pattern p: Int, ch: Int, col: Int, cc: Int, value: Float) {
        let key = "pat.\(p).ch.\(ch).cc.\(cc)"
        var lane = ccLanes[key] ?? [:]
        lane[col] = value
        ccLanes[key] = lane
    }

    /// Snapshots the current mixer state into a SceneSnapshot.
    public func captureCurrentScene(name: String = "Scene") -> SceneSnapshot {
        let nb = kAuxBusCount
        let sends: [Float] = engineRenderResources.map { rr in
            (0..<(kMaxChannels * nb)).map { rr.sendAmounts[$0] }
        } ?? Array(repeating: 0, count: kMaxChannels * nb)
        let busVols: [Float] = engineRenderResources.map { rr in
            (0..<nb).map { rr.busVolumes[$0] }
        } ?? Array(repeating: 1.0, count: nb)
        return SceneSnapshot(
            name:           name,
            channelVolumes: (0..<kMaxChannels).map { channelVolumesPtr[$0] },
            channelPans:    (0..<kMaxChannels).map { channelPansPtr[$0] },
            channelMutes:   (0..<kMaxChannels).map { channelMutesPtr[$0] },
            channelSolos:   (0..<kMaxChannels).map { channelSolosPtr[$0] },
            sendAmounts:    sends,
            busVolumes:     busVols,
            masterVolume:   Float(masterVolume),
            bpm:            bpm,
            sidechainChannel: Int32(sidechainChannel),
            sidechainAmount:  sidechainAmount)
    }

    /// Recalls a scene — applies all its fields to the current engine state.
    public func recallScene(_ scene: SceneSnapshot) {
        for i in 0..<min(kMaxChannels, scene.channelVolumes.count) { channelVolumesPtr[i] = scene.channelVolumes[i] }
        for i in 0..<min(kMaxChannels, scene.channelPans.count)    { channelPansPtr[i]    = scene.channelPans[i] }
        for i in 0..<min(kMaxChannels, scene.channelMutes.count)   { channelMutesPtr[i]   = scene.channelMutes[i] }
        for i in 0..<min(kMaxChannels, scene.channelSolos.count)   { channelSolosPtr[i]   = scene.channelSolos[i] }
        if let rr = engineRenderResources {
            let nb = kAuxBusCount
            for i in 0..<min(kMaxChannels * nb, scene.sendAmounts.count) {
                rr.sendAmounts[i] = scene.sendAmounts[i]
            }
            for i in 0..<min(nb, scene.busVolumes.count) {
                rr.busVolumes[i] = scene.busVolumes[i]
            }
        }
        masterVolume      = Double(scene.masterVolume)
        bpm               = scene.bpm
        sidechainChannel  = Int(scene.sidechainChannel)
        sidechainAmount   = scene.sidechainAmount
        mixerGeneration  += 1
    }
    
    public init() {
        instrumentBank = .allocate(capacity: 256); instrumentBank.initialize(repeating: Instrument(), count: 256)
        channelVolumesPtr = .allocate(capacity: kMaxChannels); channelVolumesPtr.initialize(repeating: 1.0, count: kMaxChannels)
        channelPansPtr    = .allocate(capacity: kMaxChannels); channelPansPtr.initialize(repeating: 0.5, count: kMaxChannels)
        channelMutesPtr   = .allocate(capacity: kMaxChannels); channelMutesPtr.initialize(repeating: 0, count: kMaxChannels)
        channelSolosPtr   = .allocate(capacity: kMaxChannels); channelSolosPtr.initialize(repeating: 0, count: kMaxChannels)
        midiChannelsPtr   = .allocate(capacity: kMaxChannels); midiChannelsPtr.initialize(repeating: 0, count: kMaxChannels)
        volEnvEnabledPtr   = .allocate(capacity: 256); volEnvEnabledPtr.initialize(repeating: 0, count: 256)
        panEnvEnabledPtr   = .allocate(capacity: 256); panEnvEnabledPtr.initialize(repeating: 0, count: 256)
        pitchEnvEnabledPtr = .allocate(capacity: 256); pitchEnvEnabledPtr.initialize(repeating: 0, count: 256)
    }
    deinit {
        instrumentBank.deallocate(); channelVolumesPtr.deallocate(); channelPansPtr.deallocate(); channelMutesPtr.deallocate(); channelSolosPtr.deallocate(); midiChannelsPtr.deallocate(); volEnvEnabledPtr.deallocate(); panEnvEnabledPtr.deallocate(); pitchEnvEnabledPtr.deallocate()
    }
    /// Per-bus names (user-facing). Stored on PlaybackState, not in the RT render path.
    public var busNames: [String] = (0..<kAuxBusCount).map { "Bus \($0 + 1)" }

    /// Returns (send amount 0…∞, bus master volume 0…∞). Reads the RT-visible arrays.
    public func getSend(channel ch: Int, bus b: Int) -> Float {
        guard ch >= 0, ch < kMaxChannels, b >= 0, b < kAuxBusCount,
              let render = engineRenderResources else { return 0 }
        return render.sendAmounts[ch * kAuxBusCount + b]
    }

    /// Sets the post-fader send amount from `channel` to `bus` (0 = none, 1 = unity).
    public func setSend(channel ch: Int, bus b: Int, amount: Float) {
        guard ch >= 0, ch < kMaxChannels, b >= 0, b < kAuxBusCount,
              let render = engineRenderResources else { return }
        render.sendAmounts[ch * kAuxBusCount + b] = max(0, amount)
        mixerGeneration += 1
    }

    /// Sets bus master volume (0 = muted, 1 = unity, >1 = gain).
    public func setBusVolume(_ v: Float, bus b: Int) {
        guard b >= 0, b < kAuxBusCount, let render = engineRenderResources else { return }
        render.busVolumes[b] = max(0, v)
        mixerGeneration += 1
    }

    /// Set by AudioHost once the AudioEngine is wired — gives PlaybackState RT-safe
    /// access to the shared bus / send arrays without the UI needing to reach through
    /// AudioEngine.renderNode.resources every call.
    public weak var engineRenderResources: RenderResources?

    public func setVolume(_ v: Float, for ch: Int) { if ch >= 0 && ch < kMaxChannels { channelVolumesPtr[ch] = v; mixerGeneration += 1 } }
    public func setPan(_ v: Float, for ch: Int) { if ch >= 0 && ch < kMaxChannels { channelPansPtr[ch] = v; mixerGeneration += 1 } }
    public func setMute(_ m: Bool, for ch: Int) { if ch >= 0 && ch < kMaxChannels { channelMutesPtr[ch] = m ? 1 : 0; mixerGeneration += 1 } }
    public func setSolo(_ s: Bool, for ch: Int) { if ch >= 0 && ch < kMaxChannels { channelSolosPtr[ch] = s ? 1 : 0; mixerGeneration += 1 } }
    public var anySolo: Bool { for i in 0..<kMaxChannels { if channelSolosPtr[i] != 0 { return true } }; return false }
    public var automationLanes: [Int: [BezierAutomationLane]] = [:]; public var channelPositions: [Int: SIMD3<Float>] = [:]
    public func snapshotForUndo(label: String = "Edit") {
        let count = kMaxChannels * 64 * 100; let copy = Array(UnsafeBufferPointer(start: sequencerData.events, count: count))
        if undoStack.count >= 50 { undoStack.removeFirst(); undoLabels.removeFirst() }
        undoStack.append(copy)
        undoLabels.append(label)
        redoStack.removeAll()
    }
    public func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        _ = undoLabels.popLast()
        let count = kMaxChannels * 64 * 100; let copy = Array(UnsafeBufferPointer(start: sequencerData.events, count: count))
        redoStack.append(copy); snapshot.withUnsafeBufferPointer { src in guard let base = src.baseAddress else { return }; memcpy(sequencerData.events, base, count * MemoryLayout<TrackerEvent>.size) }
        textureInvalidationTrigger += 1
    }
    public func redo() {
        guard let snapshot = redoStack.popLast() else { return }; let count = kMaxChannels * 64 * 100; let copy = Array(UnsafeBufferPointer(start: sequencerData.events, count: count))
        undoStack.append(copy); snapshot.withUnsafeBufferPointer { src in guard let base = src.baseAddress else { return }; memcpy(sequencerData.events, base, count * MemoryLayout<TrackerEvent>.size) }
        textureInvalidationTrigger += 1
    }
    public func isEnvelopeEnabled(type: Int, instrument: Int) -> Bool {
        guard instrument >= 0 && instrument < 256 else { return false }
        if type == 0 { return volEnvEnabledPtr[instrument] != 0 }
        if type == 1 { return panEnvEnabledPtr[instrument] != 0 }
        return pitchEnvEnabledPtr[instrument] != 0
    }
    public func setEnvelopeEnabled(_ enabled: Bool, type: Int, instrument: Int) {
        guard instrument >= 0 && instrument < 256 else { return }
        let val: Int32 = enabled ? 1 : 0
        if type == 0 { volEnvEnabledPtr[instrument] = val } else if type == 1 { panEnvEnabledPtr[instrument] = val } else { pitchEnvEnabledPtr[instrument] = val }
        mixerGeneration += 1
    }
    /// Displays `message` in the HUD overlay for ~5 s. Long enough for users to
    /// actually read; short enough that stale state doesn't linger across
    /// distinct actions. The message clears itself only if it hasn't been
    /// replaced by a newer status, so rapid-fire status calls don't truncate
    /// each other.
    public func showStatus(_ message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if statusMessage == message { statusMessage = nil }
        }
    }
}

public enum WorkbenchTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", patterns = "Sequencer", pianoRoll = "Piano Roll", mixer = "Mastering", automation = "Automation", spatial = "Spatial 3D", spectral = "Spectral", plugins = "DSP Rack", video = "Video Sync", midi = "MIDI I/O", neural = "Neural", instruments = "Envelopes", samples = "Waveform"
    public var id: String { self.rawValue }
    public var icon: String {
        switch self {
        case .dashboard: return "house.fill"; case .patterns: return "pianokeys"; case .instruments: return "waveform.path.ecg"; case .samples: return "waveform"; case .pianoRoll: return "pianokeys.inverse"; case .mixer: return "slider.vertical.3"; case .automation: return "chart.line.uptrend.xyaxis"; case .spatial: return "arkit"; case .video: return "video.fill"; case .plugins: return "fx"; case .midi: return "cable.connector"; case .neural: return "brain.head.profile"; case .spectral: return "waveform.and.magnifyingglass"
        }
    }
}
