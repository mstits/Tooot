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
    
    public var masterVolume: Double = 0.8; public var isStereoWideEnabled: Bool = false; public var isReverbEnabled: Bool = false
    public var isMetronomeEnabled: Bool = false; public var isMasterLimiterEnabled: Bool = true
    public var sidechainChannel: Int = -1; public var sidechainAmount: Float = 0.0
    public var bpm: Int = 125; public var ticksPerRow: Int = 6; public var activeTier: SynthesisTier = .carbon
    
    public var carbonCorruption: Float = 0.0
    public var carbonGlitchRate: Float = 0.0
    public var bioArrhythmiaRate: Float = 0.0
    public var bioBreathiness: Float = 0.0
    public var xenoFractalDim: Float = 1.0
    public var xenoVoidThreshold: Float = 0.5
    
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
    public func setVolume(_ v: Float, for ch: Int) { if ch >= 0 && ch < kMaxChannels { channelVolumesPtr[ch] = v; mixerGeneration += 1 } }
    public func setPan(_ v: Float, for ch: Int) { if ch >= 0 && ch < kMaxChannels { channelPansPtr[ch] = v; mixerGeneration += 1 } }
    public func setMute(_ m: Bool, for ch: Int) { if ch >= 0 && ch < kMaxChannels { channelMutesPtr[ch] = m ? 1 : 0; mixerGeneration += 1 } }
    public func setSolo(_ s: Bool, for ch: Int) { if ch >= 0 && ch < kMaxChannels { channelSolosPtr[ch] = s ? 1 : 0; mixerGeneration += 1 } }
    public var anySolo: Bool { for i in 0..<kMaxChannels { if channelSolosPtr[i] != 0 { return true } }; return false }
    public var automationLanes: [Int: [AutomationLane]] = [:]; public var channelPositions: [Int: SIMD3<Float>] = [:]
    public func snapshotForUndo() {
        let count = kMaxChannels * 64 * 100; let copy = Array(UnsafeBufferPointer(start: sequencerData.events, count: count))
        if undoStack.count >= 50 { undoStack.removeFirst() }; undoStack.append(copy); redoStack.removeAll()
    }
    public func undo() {
        guard let snapshot = undoStack.popLast() else { return }; let count = kMaxChannels * 64 * 100; let copy = Array(UnsafeBufferPointer(start: sequencerData.events, count: count))
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
    public func showStatus(_ message: String) { statusMessage = message; Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if statusMessage == message { statusMessage = nil } } }
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
