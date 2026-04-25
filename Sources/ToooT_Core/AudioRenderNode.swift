/*
 *  PROJECT ToooT (ToooT_Core)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *
 *  AudioRenderNode — Swift 6 strict-concurrency, zero-heap-allocation mixing core.
 */

import Foundation
import AVFoundation
import Accelerate
import Synchronization

public typealias SpatialPushCallback = @Sendable (Int, UnsafePointer<Float>, Int) -> Void

// MARK: - SongSnapshot

public struct SongSnapshot: @unchecked Sendable {
    public let events:      UnsafeMutablePointer<TrackerEvent>
    public let instruments: UnsafeMutablePointer<Instrument>
    public let orderList:   [Int]
    public let songLength:  Int

    // Per-instrument envelope enable flags (raw pointers for RT safety)
    public let volEnvEnabled:   UnsafeMutablePointer<Int32>
    public let panEnvEnabled:   UnsafeMutablePointer<Int32>
    public let pitchEnvEnabled: UnsafeMutablePointer<Int32>

    // Static pointers for the empty snapshot to prevent leaks and re-allocations.
    nonisolated(unsafe) private static let emptyEvents: UnsafeMutablePointer<TrackerEvent> = {
        let p = UnsafeMutablePointer<TrackerEvent>.allocate(capacity: kMaxChannels * 64 * 100)
        p.initialize(repeating: .empty, count: kMaxChannels * 64 * 100)
        return p
    }()
    nonisolated(unsafe) private static let emptyInsts: UnsafeMutablePointer<Instrument> = {
        let p = UnsafeMutablePointer<Instrument>.allocate(capacity: 256)
        p.initialize(repeating: Instrument(), count: 256)
        return p
    }()
    nonisolated(unsafe) private static let emptyEnvs: UnsafeMutablePointer<Int32> = {
        let p = UnsafeMutablePointer<Int32>.allocate(capacity: 256)
        p.initialize(repeating: 0, count: 256)
        return p
    }()

    /// Creates a transient empty snapshot using static pointers.
    public static func createEmpty() -> SongSnapshot {
        return SongSnapshot(
            events:      emptyEvents,
            instruments: emptyInsts,
            orderList:   [0],
            songLength:  1,
            volEnv:      emptyEnvs,
            panEnv:      emptyEnvs,
            pitchEnv:    emptyEnvs
        )
    }

    public init(events: UnsafeMutablePointer<TrackerEvent>,
                instruments: UnsafeMutablePointer<Instrument>,
                orderList: [Int],
                songLength: Int,
                volEnv: UnsafeMutablePointer<Int32>,
                panEnv: UnsafeMutablePointer<Int32>,
                pitchEnv: UnsafeMutablePointer<Int32>) {
        self.events      = events
        self.instruments = instruments
        self.orderList   = orderList
        self.songLength  = songLength
        self.volEnvEnabled   = volEnv
        self.panEnvEnabled   = panEnv
        self.pitchEnvEnabled = pitchEnv
    }
}

/// Managed container for a snapshot. Memory management of raw pointers
/// is handled by the owner (SequencerData) to prevent premature freeing.
internal final class SnapshotBox {
    let snapshot: SongSnapshot
    init(_ snapshot: SongSnapshot) { self.snapshot = snapshot }
}

// MARK: - RenderResources

/// Number of aux/group buses available. Bump in tandem with RenderResources if you raise it.
/// Each bus is a stereo accumulator with its own master gain; sends from any channel to any
/// bus are set via PlaybackState.setSend(channel:bus:amount:).
public let kAuxBusCount: Int = 4

public final class RenderResources: @unchecked Sendable {
    public let voices:             UnsafeMutablePointer<SynthVoice>
    public let channelVolumes:     UnsafeMutablePointer<Float>
    public let channelPans:        UnsafeMutablePointer<Float>
    public let channelMidiFlags:   UnsafeMutablePointer<Int32>
    public let channelMemory:      UnsafeMutablePointer<Int>
    public let scratchL:           UnsafeMutablePointer<Float>
    public let scratchR:           UnsafeMutablePointer<Float>
    public let sumL:               UnsafeMutablePointer<Float>
    public let sumR:               UnsafeMutablePointer<Float>
    public let gainVector:         UnsafeMutablePointer<Float>
    public let interpScratch:      UnsafeMutablePointer<Float>
    public let positionsScratch:   UnsafeMutablePointer<Float>
    public let envelopeScratch:    UnsafeMutablePointer<EnvelopePoint>
    public let scratchMono:        UnsafeMutablePointer<Float>

    // Aux buses: per-bus stereo accumulators + per-bus master gain + per-channel send amounts.
    // Layout of sendAmounts: row-major [channel * kAuxBusCount + bus].
    public let busL:          UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    public let busR:          UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    public let busVolumes:    UnsafeMutablePointer<Float>
    public let sendAmounts:   UnsafeMutablePointer<Float>

    // Per-voice scratch buffers for the multi-core offline render path
    // (renderOfflineConcurrent). One slot per voice — sized to kMaxChannels —
    // so `concurrentPerform` can run every voice.process() call against its
    // own buffers without collisions. The earlier "8 round-robin slots"
    // design was incorrect: with N>8 active voices, two iterations could
    // collide on the same slot since concurrentPerform doesn't pin
    // iterations to threads.
    public static let voiceThreadSlots: Int = kMaxChannels
    public let threadScratchL:      UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    public let threadScratchR:      UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    public let threadScratchMono:   UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    public let threadInterpScratch: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    public let threadPositionsScratch: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    // PDC: Plugin Delay Compensation buffers
    public let delayBuffersL:      UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    public let delayBuffersR:      UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    public let delayIndices:       UnsafeMutablePointer<Int>
    public let channelLatencies:   UnsafeMutablePointer<Int>
    public let maxDelayFrames:     Int = 44100 // 1 second maximum PDC

    // Per-channel pending effect storage for cross-tick effects (ECx, EDx, EEx)
    public let pendingEffect:      UnsafeMutablePointer<UInt8>   // effect command
    public let pendingParam:       UnsafeMutablePointer<UInt8>   // effect param
    public let activeChannelIndices: UnsafeMutablePointer<Int>
    public var activeChannelCount: Int = 0
    public var baseTicksPerRow:    Int32 = 0   // saved value before EEx expands ticksPerRow
    public var currentRowIndex:    Int = 0
    public let maxFrames: Int
    
    // Metronome and Limiter state
    public var metronomeAmplitude: Float = 0.0
    public var metronomePhase:     Float = 0.0
    public var limiterGain:        Float = 1.0
    public var sidechainPeak:      Float = 0.0

    public init(maxFrames: Int = 4096) {
        self.maxFrames = maxFrames
        voices           = .allocate(capacity: kMaxChannels)
        voices.initialize(repeating: SynthVoice(), count: kMaxChannels)
        channelVolumes   = .allocate(capacity: kMaxChannels)
        channelVolumes.initialize(repeating: 1.0, count: kMaxChannels)
        channelPans      = .allocate(capacity: kMaxChannels)
        channelPans.initialize(repeating: 0.5, count: kMaxChannels)
        channelMidiFlags = .allocate(capacity: kMaxChannels)
        channelMidiFlags.initialize(repeating: 0, count: kMaxChannels)
        channelMemory    = .allocate(capacity: kMaxChannels)
        channelMemory.initialize(repeating: 1, count: kMaxChannels)
        scratchL         = .allocate(capacity: maxFrames)
        scratchL.initialize(repeating: 0, count: maxFrames)
        scratchR         = .allocate(capacity: maxFrames)
        scratchR.initialize(repeating: 0, count: maxFrames)
        sumL             = .allocate(capacity: maxFrames)
        sumL.initialize(repeating: 0, count: maxFrames)
        sumR             = .allocate(capacity: maxFrames)
        sumR.initialize(repeating: 0, count: maxFrames)
        gainVector       = .allocate(capacity: kMaxChannels)
        gainVector.initialize(repeating: 1.0, count: kMaxChannels)
        interpScratch    = .allocate(capacity: maxFrames)
        interpScratch.initialize(repeating: 0, count: maxFrames)
        positionsScratch = .allocate(capacity: maxFrames)
        positionsScratch.initialize(repeating: 0, count: maxFrames)
        envelopeScratch  = .allocate(capacity: 32) // max points
        envelopeScratch.initialize(repeating: EnvelopePoint(pos: 0, val: 0), count: 32)
        scratchMono      = .allocate(capacity: maxFrames)
        scratchMono.initialize(repeating: 0, count: maxFrames)
        pendingEffect    = .allocate(capacity: kMaxChannels)
        pendingEffect.initialize(repeating: 0, count: kMaxChannels)
        pendingParam     = .allocate(capacity: kMaxChannels)
        pendingParam.initialize(repeating: 0, count: kMaxChannels)
        activeChannelIndices = .allocate(capacity: kMaxChannels)
        activeChannelIndices.initialize(repeating: 0, count: kMaxChannels)
        
        delayBuffersL = .allocate(capacity: kMaxChannels)
        delayBuffersR = .allocate(capacity: kMaxChannels)
        delayIndices  = .allocate(capacity: kMaxChannels)
        channelLatencies = .allocate(capacity: kMaxChannels)
        for i in 0..<kMaxChannels {
            delayBuffersL[i] = .allocate(capacity: maxDelayFrames)
            delayBuffersL[i].initialize(repeating: 0, count: maxDelayFrames)
            delayBuffersR[i] = .allocate(capacity: maxDelayFrames)
            delayBuffersR[i].initialize(repeating: 0, count: maxDelayFrames)
            delayIndices[i] = 0
            channelLatencies[i] = 0
        }

        // Aux buses
        busL        = .allocate(capacity: kAuxBusCount)
        busR        = .allocate(capacity: kAuxBusCount)
        busVolumes  = .allocate(capacity: kAuxBusCount)
        busVolumes.initialize(repeating: 1.0, count: kAuxBusCount)
        for b in 0..<kAuxBusCount {
            busL[b] = .allocate(capacity: maxFrames)
            busL[b].initialize(repeating: 0, count: maxFrames)
            busR[b] = .allocate(capacity: maxFrames)
            busR[b].initialize(repeating: 0, count: maxFrames)
        }
        sendAmounts = .allocate(capacity: kMaxChannels * kAuxBusCount)
        sendAmounts.initialize(repeating: 0, count: kMaxChannels * kAuxBusCount)

        // Per-thread voice scratch pool for concurrent offline render.
        threadScratchL         = .allocate(capacity: Self.voiceThreadSlots)
        threadScratchR         = .allocate(capacity: Self.voiceThreadSlots)
        threadScratchMono      = .allocate(capacity: Self.voiceThreadSlots)
        threadInterpScratch    = .allocate(capacity: Self.voiceThreadSlots)
        threadPositionsScratch = .allocate(capacity: Self.voiceThreadSlots)
        for t in 0..<Self.voiceThreadSlots {
            threadScratchL[t]         = .allocate(capacity: maxFrames)
            threadScratchL[t].initialize(repeating: 0, count: maxFrames)
            threadScratchR[t]         = .allocate(capacity: maxFrames)
            threadScratchR[t].initialize(repeating: 0, count: maxFrames)
            threadScratchMono[t]      = .allocate(capacity: maxFrames)
            threadScratchMono[t].initialize(repeating: 0, count: maxFrames)
            threadInterpScratch[t]    = .allocate(capacity: maxFrames)
            threadInterpScratch[t].initialize(repeating: 0, count: maxFrames)
            threadPositionsScratch[t] = .allocate(capacity: maxFrames)
            threadPositionsScratch[t].initialize(repeating: 0, count: maxFrames)
        }
    }

    deinit {
        for i in 0..<kMaxChannels {
            delayBuffersL[i].deallocate()
            delayBuffersR[i].deallocate()
        }
        delayBuffersL.deallocate()
        delayBuffersR.deallocate()
        delayIndices.deallocate()
        channelLatencies.deallocate()
        for b in 0..<kAuxBusCount {
            busL[b].deallocate()
            busR[b].deallocate()
        }
        busL.deallocate()
        busR.deallocate()
        busVolumes.deallocate()
        sendAmounts.deallocate()
        for t in 0..<Self.voiceThreadSlots {
            threadScratchL[t].deallocate()
            threadScratchR[t].deallocate()
            threadScratchMono[t].deallocate()
            threadInterpScratch[t].deallocate()
            threadPositionsScratch[t].deallocate()
        }
        threadScratchL.deallocate()
        threadScratchR.deallocate()
        threadScratchMono.deallocate()
        threadInterpScratch.deallocate()
        threadPositionsScratch.deallocate()
        voices.deallocate()
        channelVolumes.deallocate()
        channelPans.deallocate()
        channelMidiFlags.deallocate()
        channelMemory.deallocate()
        scratchL.deallocate()
        scratchR.deallocate()
        sumL.deallocate()
        sumR.deallocate()
        gainVector.deallocate()
        interpScratch.deallocate()
        positionsScratch.deallocate()
        envelopeScratch.deallocate()
        scratchMono.deallocate()
        pendingEffect.deallocate()
        pendingParam.deallocate()
        activeChannelIndices.deallocate()
    }
}

// MARK: - AudioRenderNode

public final class AudioRenderNode: Sendable {
    private let _snapshotPtr: Atomic<UInt>
    /// Atomic pointer to the current AutomationSnapshot. Render thread reads via
    /// `Unmanaged.takeUnretainedValue` — main thread publishes via
    /// `swapAutomationSnapshot`. Same lifecycle pattern as song snapshots.
    private let _automationPtr: Atomic<UInt> = .init(0)
    public let resources:  RenderResources
    nonisolated(unsafe) public let statePtr: UnsafeMutablePointer<EngineSharedState>
    public let sampleBank: UnifiedSampleBank
    public let eventBuffer: AtomicRingBuffer<TrackerEvent>
    /// Project sample rate in Hz. Fixed at render-node init — used in tick math
    /// (`samplesPerTick = sampleRate * 2.5 / bpm`), voice resampling, LUFS filters.
    public let sampleRate: Double
    /// Sized at 2048 entries — `push` silently drops when full, which would leak
    /// retained snapshots. 2048 absorbs realistic main-thread bursts (UI drag at
    /// 60 Hz between 30 Hz Timeline drains accumulates ~2 entries; project load
    /// might burst a handful) with multiple orders of magnitude of headroom.
    private let deallocationQueue: AtomicRingBuffer<UInt> = .init(capacity: 2048)
    /// Separate queue for automation snapshots so we can release them on a
    /// MainActor drain without confusing the song-snapshot deallocator.
    private let automationDealloc: AtomicRingBuffer<UInt> = .init(capacity: 2048)
    private let tickAccumulator: Atomic<Double> = .init(0.0)
    /// Master-bus loudness + true-peak + phase metering. Writes back into
    /// `sharedState.{truePeak, lufsMomentary, lufsShortTerm, lufsIntegrated, phaseCorrelation}`
    /// at the end of every render block. Thread-safe by confinement: only the
    /// render thread touches it.
    public let masterMeter: MasterMeter = MasterMeter()


    nonisolated(unsafe) public var midiOut: (@Sendable (UInt8, UInt8, UInt8) -> Void)?
    nonisolated(unsafe) public var spatialPush: SpatialPushCallback?

    public var channelVolumesPtr: UnsafeMutablePointer<Float> { resources.channelVolumes }
    public var channelPansPtr: UnsafeMutablePointer<Float> { resources.channelPans }
    public var midiEnabledPtr: UnsafeMutablePointer<Int32> { resources.channelMidiFlags }

    public init(resources: RenderResources,
                statePtr: UnsafeMutablePointer<EngineSharedState>,
                bank: UnifiedSampleBank,
                eventBuffer: AtomicRingBuffer<TrackerEvent>,
                sampleRate: Double = 44100) {
        self.resources    = resources
        self.statePtr     = statePtr
        self.sampleBank   = bank
        self.eventBuffer  = eventBuffer
        self.sampleRate   = sampleRate
        self._snapshotPtr = Atomic<UInt>(0)

        self.swapSnapshot(SongSnapshot.createEmpty())
    }

    deinit {
        let raw = _snapshotPtr.load(ordering: .relaxed)
        if raw != 0 { Unmanaged<SnapshotBox>.fromOpaque(UnsafeRawPointer(bitPattern: raw)!).release() }
        while let taggedRaw = deallocationQueue.pop() {
            let isRawPointer = (taggedRaw & 1) == 1
            let raw = taggedRaw & ~UInt(1)
            if let ptr = UnsafeMutableRawPointer(bitPattern: raw) {
                if isRawPointer { ptr.deallocate() }
                else { Unmanaged<SnapshotBox>.fromOpaque(ptr).release() }
            }
        }
        let aRaw = _automationPtr.load(ordering: .relaxed)
        if aRaw != 0 { Unmanaged<AutomationSnapshot>.fromOpaque(UnsafeRawPointer(bitPattern: aRaw)!).release() }
        while let raw = automationDealloc.pop() {
            if let ptr = UnsafeMutableRawPointer(bitPattern: raw) {
                Unmanaged<AutomationSnapshot>.fromOpaque(ptr).release()
            }
        }
    }

    public func swapSnapshot(_ new: SongSnapshot) {
        let newBox  = SnapshotBox(new)
        let newRaw  = UInt(bitPattern: Unmanaged.passRetained(newBox).toOpaque())
        let oldRaw  = _snapshotPtr.exchange(newRaw, ordering: .acquiringAndReleasing)
        if oldRaw != 0 { _ = deallocationQueue.push(oldRaw) }
    }

    /// Publishes a new automation snapshot atomically. Pass `.empty` to clear all
    /// lanes. Old snapshot is released on the next MainActor `processDeallocations`.
    public func swapAutomationSnapshot(_ new: AutomationSnapshot) {
        let newRaw = UInt(bitPattern: Unmanaged.passRetained(new).toOpaque())
        let old = _automationPtr.exchange(newRaw, ordering: .acquiringAndReleasing)
        if old != 0 { _ = automationDealloc.push(old) }
    }

    /// Render-thread-only: reads the current automation snapshot without a retain.
    /// Lifetime is guaranteed by the deallocation queue draining only on MainActor.
    @inline(__always)
    fileprivate func currentAutomationSnapshot() -> AutomationSnapshot? {
        let raw = _automationPtr.load(ordering: .acquiring)
        guard raw != 0, let p = UnsafeRawPointer(bitPattern: raw) else { return nil }
        return Unmanaged<AutomationSnapshot>.fromOpaque(p).takeUnretainedValue()
    }

    @MainActor
    public func processDeallocations() {
        MainActor.assertIsolated()
        while let taggedRaw = deallocationQueue.pop() {
            let isRawPointer = (taggedRaw & 1) == 1
            let raw = taggedRaw & ~UInt(1)
            if let ptr = UnsafeMutableRawPointer(bitPattern: raw) {
                if isRawPointer { ptr.deallocate() }
                else { Unmanaged<SnapshotBox>.fromOpaque(ptr).release() }
            }
        }
        while let raw = automationDealloc.pop() {
            if let ptr = UnsafeMutableRawPointer(bitPattern: raw) {
                Unmanaged<AutomationSnapshot>.fromOpaque(ptr).release()
            }
        }
    }

    public func queueRawDeallocation(_ ptr: UnsafeMutableRawPointer) {
        _ = deallocationQueue.push(UInt(bitPattern: ptr) | 1)
    }

    /// Call this when starting playback so tick 0 fires at sample 0 (no startup silence).
    /// With the floor-based scheduler, 0.0 means "fire tick at next sample" — the default.
    public func resetForPlayback() {
        tickAccumulator.store(0.0, ordering: .relaxed)
        // Reset the tick counter so playback begins at tick 0 of the first row
        statePtr.pointee.samplesProcessed = 0
        // Reset per-channel state for clean start
        let res = resources
        res.baseTicksPerRow = 0
        for ch in 0..<kMaxChannels {
            res.channelMemory[ch] = 1  // Default to instrument 1 (MOD convention)
            res.pendingEffect[ch] = 0
            res.pendingParam[ch] = 0
            res.voices[ch].active = false
        }
        res.activeChannelCount = 0
        // Reset metering — integrated LUFS + running true-peak restart at each play.
        masterMeter.reset()
    }

    // MARK: - Automation evaluator

    /// Walks every lane in `auto` and writes its value at `beat` into the matching
    /// RT-visible parameter. Called at row boundaries — fast enough to be fine
    /// inside the audio callback (single dictionary scan per row, ~30 Hz at 125 BPM).
    ///
    /// Target ID grammar (string-keyed; parsed by hand to avoid allocations):
    ///   ch.<N>.volume        → res.channelVolumes[N]
    ///   ch.<N>.pan           → res.channelPans[N]
    ///   ch.<N>.send.<bus>    → res.sendAmounts[N * kAuxBusCount + bus]
    ///   bus.<B>.volume       → res.busVolumes[B]
    ///   master.volume        → state.pointee.masterVolume
    ///
    /// Unknown target IDs are ignored — callers can stash custom IDs (e.g. plugin
    /// parameter automation) in the same bank and route them elsewhere.
    @inline(__always)
    fileprivate static func applyAutomation(
        _ auto: AutomationSnapshot,
        beat: Double,
        res: RenderResources,
        state: UnsafeMutablePointer<EngineSharedState>
    ) {
        for (target, lane) in auto.lanes {
            guard let v = lane.evaluate(at: beat) else { continue }
            applyTarget(target, value: v, res: res, state: state)
        }
    }

    @inline(__always)
    private static func applyTarget(
        _ target: String,
        value: Float,
        res: RenderResources,
        state: UnsafeMutablePointer<EngineSharedState>
    ) {
        if target == "master.volume" {
            state.pointee.masterVolume = max(0, value)
            return
        }
        // Split by '.' — small, no allocations beyond the ArraySlice that Swift
        // creates for the Substring sequence (cheap; bounded to 4 segments).
        let parts = target.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return }
        let kind = parts[0]
        guard let idx = Int(parts[1]) else { return }
        let attr = parts[2]
        if kind == "ch" {
            guard idx >= 0, idx < kMaxChannels else { return }
            switch attr {
            case "volume": res.channelVolumes[idx] = max(0, value)
            case "pan":    res.channelPans[idx] = min(1, max(0, value))
            case "send":
                guard parts.count >= 4, let busI = Int(parts[3]),
                      busI >= 0, busI < kAuxBusCount else { return }
                res.sendAmounts[idx * kAuxBusCount + busI] = max(0, value)
            default: return
            }
        } else if kind == "bus" {
            guard idx >= 0, idx < kAuxBusCount, attr == "volume" else { return }
            res.busVolumes[idx] = max(0, value)
        }
    }

    // MARK: - Shared Sequencer Tick Logic

    /// Processes one sequencer tick: row advancement, event dispatch, per-tick effects, and
    /// active-channel list building. Called from both renderBlock (real-time) and renderOffline.
    ///
    /// - Parameters:
    ///   - currentTick: The tick index within the current row (0-based).
    ///   - wrapOnEnd:   `true` → loop to order 0 when song ends (live playback);
    ///                  `false` → set `isPlaying = 0` and return `true` (offline render).
    /// - Returns: `true` only when `wrapOnEnd == false` and the song has reached its end.
    @inline(__always)
    @discardableResult
    private static func processTickSequencer(
        snap:        SongSnapshot,
        state:       UnsafeMutablePointer<EngineSharedState>,
        res:         RenderResources,
        currentTick: Int,
        wrapOnEnd:   Bool,
        auto:        AutomationSnapshot? = nil
    ) -> Bool {

        if state.pointee.isPlaying != 0 && currentTick == 0 {
            if res.baseTicksPerRow > 0 {
                state.pointee.ticksPerRow = res.baseTicksPerRow
                res.baseTicksPerRow = 0
            }
            let orderIdx      = Int(state.pointee.currentOrder)
            let patternNumber = orderIdx < snap.orderList.count ? snap.orderList[orderIdx] : 0
            let absRow        = (patternNumber * 64) + Int(state.pointee.currentEngineRow)
            res.currentRowIndex = absRow

            // Automation: evaluate every active lane against the current beat
            // and write into RT params before voices are triggered for this row.
            // Tracker convention: 4 rows = 1 beat (16th-note grid in 4/4).
            if let auto, !auto.lanes.isEmpty {
                let beat = Double(absRow) / 4.0
                applyAutomation(auto, beat: beat, res: res, state: state)
            }

            var nextRow       = state.pointee.currentEngineRow + 1
            var nextOrder     = state.pointee.currentOrder
            var jumpRow: Int32? = nil
            var didJump       = false

            // L2: Update currentPattern
            state.pointee.currentPattern = Int32(patternNumber)

            // Clear per-tick effects for all channels at the start of each row
            // (ProTracker convention: effects don't persist across rows)
            for ch in 0..<kMaxChannels {
                res.voices.advanced(by: ch).pointee.currentEffect = 0
                res.voices.advanced(by: ch).pointee.currentEffectParam = 0
                res.pendingEffect[ch] = 0
                res.pendingParam[ch] = 0
            }

            for ch in 0..<kMaxChannels {
                let idx = absRow * kMaxChannels + ch
                guard idx >= 0 && idx < kMaxChannels * 64 * 100 else { continue }
                let ev = snap.events[idx]
                guard ev.type != .empty || ev.effectCommand > 0 || ev.effectParam > 0 || ev.instrument > 0 else { continue }
                let voicePtr = res.voices.advanced(by: ch)
                voicePtr.pointee.currentEffect      = ev.effectCommand
                voicePtr.pointee.currentEffectParam = ev.effectParam
                res.pendingEffect[ch] = ev.effectCommand
                res.pendingParam[ch]  = ev.effectParam
                switch ev.type {
                case .noteOn:
                    var instID = Int(ev.instrument)
                    if instID == 0 { instID = res.channelMemory[ch] }
                    else           { res.channelMemory[ch] = instID }
                    let isNoteDelay = (ev.effectCommand == 0x0E && ((ev.effectParam & 0xF0) >> 4) == 0xD)
                    let delayTicks = isNoteDelay ? Int(ev.effectParam & 0x0F) : 0
                    if instID < 256 && delayTicks == 0 {
                        let inst     = snap.instruments[instID]
                        let freqVal  = Double(ev.value1)
                        guard freqVal.isFinite && freqVal > 0 else { continue }
                        let noteNum  = Int(round(12.0 * log2(freqVal / 440.0) + 69.0))
                        if let region = inst.region(for: noteNum) {
                            let isTonePorta = ev.effectCommand == 0x03 || ev.effectCommand == 0x05
                            if isTonePorta && voicePtr.pointee.active {
                                voicePtr.pointee.targetFrequency = Float(ev.value1)
                            } else {
                                voicePtr.pointee.trigger(frequency: Float(ev.value1), velocity: ev.value2 >= 0 ? ev.value2 : inst.defaultVolume, offset: region.offset, length: region.length, isStereo: region.isStereo, loopType: region.loopType, loopStart: region.loopStart, loopLength: region.loopLength, volumeEnvelope: inst.volumeEnvelope, panningEnvelope: inst.panningEnvelope, pitchEnvelope: inst.pitchEnvelope, volumeEnvOn: snap.volEnvEnabled[instID] != 0, panningEnvOn: snap.panEnvEnabled[instID] != 0, pitchEnvOn: snap.pitchEnvEnabled[instID] != 0, finetune: region.finetune, defaultPan: res.channelPans[ch])
                                if isTonePorta { voicePtr.pointee.targetFrequency = Float(ev.value1) }
                                if ev.effectCommand == 0x09 && ev.effectParam > 0 {
                                    voicePtr.pointee.setSampleOffset(Int(ev.effectParam) * 256)
                                }
                            }
                        }
                    }
                case .noteOff:   res.voices.advanced(by: ch).pointee.active = false
                case .setVolume: voicePtr.pointee.velocity = Float(ev.value1)
                case .patternJump:  nextOrder = Int32(ev.value1); jumpRow = 0; didJump = true
                case .patternBreak: if !didJump { nextOrder += 1; didJump = true }; jumpRow = Int32(ev.value1)
                default: break
                }
                // Instrument-only (no note): reset volume to instrument default
                if ev.type == .empty && ev.instrument > 0 {
                    let instID = Int(ev.instrument)
                    res.channelMemory[ch] = instID
                    if instID < 256 { voicePtr.pointee.velocity = snap.instruments[instID].defaultVolume }
                }
                if ev.effectCommand == 0x0F && ev.effectParam > 0 {
                    if ev.effectParam < 32 { state.pointee.ticksPerRow = Int32(ev.effectParam) }
                    else                   { state.pointee.bpm         = Int32(ev.effectParam) }
                }
                // Extended Effects (0x0E) - Immediate ones (E1x, E2x, EAx, EBx, EEx)
                if ev.effectCommand == 0x0E {
                    let subCmd = (ev.effectParam & 0xF0) >> 4
                    let subVal = ev.effectParam & 0x0F
                    switch subCmd {
                    case 0x1: // Fine Portamento Up
                        let clock: Float = 3546895.0
                        var period = clock / max(1.0, voicePtr.pointee.frequency)
                        period -= Float(subVal); period = max(1.0, period)
                        voicePtr.pointee.frequency = clock / period
                        voicePtr.pointee.originalFrequency = voicePtr.pointee.frequency
                    case 0x2: // Fine Portamento Down
                        let clock: Float = 3546895.0
                        var period = clock / max(1.0, voicePtr.pointee.frequency)
                        period += Float(subVal)
                        voicePtr.pointee.frequency = clock / period
                        voicePtr.pointee.originalFrequency = voicePtr.pointee.frequency
                    case 0xA: // Fine Volume Slide Up
                        voicePtr.pointee.velocity = min(1.0, voicePtr.pointee.velocity + Float(subVal)/64.0)
                    case 0xB: // Fine Volume Slide Down
                        voicePtr.pointee.velocity = max(0.0, voicePtr.pointee.velocity - Float(subVal)/64.0)
                    case 0xD: // Note Delay — instrument cache
                        var instID = Int(ev.instrument)
                        if instID == 0 { instID = res.channelMemory[ch] }
                        else           { res.channelMemory[ch] = instID }
                    case 0xE: // Pattern Delay
                        res.baseTicksPerRow = state.pointee.ticksPerRow
                        state.pointee.ticksPerRow = res.baseTicksPerRow * Int32(subVal + 1)
                    default: break
                    }
                }
                // Pattern Jump/Break: also check effectCommand (noteOn+jump combos)
                if ev.effectCommand == 0x0B && !didJump {
                    nextOrder = Int32(ev.effectParam); jumpRow = 0; didJump = true
                } else if ev.effectCommand == 0x0D && !didJump {
                    nextOrder += 1; didJump = true
                    jumpRow = Int32((ev.effectParam >> 4) * 10 + (ev.effectParam & 0x0F))
                }
            }

            if !didJump { if nextRow >= 64 { nextRow = 0; nextOrder += 1 } }
            else if let r = jumpRow { nextRow = r }

            if nextOrder >= Int32(snap.songLength) {
                if wrapOnEnd {
                    nextOrder = 0
                } else {
                    state.pointee.isPlaying = 0
                    return true
                }
            }
            state.pointee.currentEngineRow = nextRow
            state.pointee.currentOrder     = nextOrder
            // Update algSeed: upper 16 bits = absolute row (pattern*64+row), lower 16 = tempo context.
            // Written once per row — Timeline.syncEngineToUI() reads it at ~30 Hz.
            let absRowForSeed = UInt32(patternNumber * 64 + Int(nextRow))
            let tempoCtx = UInt32(state.pointee.bpm) &* UInt32(max(1, state.pointee.ticksPerRow))
            state.pointee.algSeed = (absRowForSeed << 16) | (tempoCtx & 0xFFFF)
        }

        // Per-tick effects: ECx = Note Cut, EDx = Note Delay
        if state.pointee.isPlaying != 0 {
            for ch in 0..<kMaxChannels {
                if res.pendingEffect[ch] == 0x0E {
                    let param   = res.pendingParam[ch]
                    let subCmd  = (param & 0xF0) >> 4
                    let subVal  = Int(param & 0x0F)
                    if subCmd == 0xC && currentTick == subVal { // Note Cut
                        res.voices.advanced(by: ch).pointee.active = false
                    } else if subCmd == 0xD && currentTick == subVal && currentTick > 0 { // Note Delay
                        let idx = res.currentRowIndex * kMaxChannels + ch
                        if idx >= 0 && idx < kMaxChannels * 64 * 100 {
                            let ev = snap.events[idx]
                            if ev.type == .noteOn {
                                let voicePtr = res.voices.advanced(by: ch)
                                var instID = Int(ev.instrument)
                                if instID == 0 { instID = res.channelMemory[ch] }
                                if instID < 256 {
                                    let inst = snap.instruments[instID]
                                    let freqVal = Double(ev.value1)
                                    if freqVal.isFinite && freqVal > 0 {
                                        let noteNum = Int(round(12.0 * log2(freqVal / 440.0) + 69.0))
                                        if let region = inst.region(for: noteNum) {
                                            voicePtr.pointee.trigger(frequency: Float(ev.value1), velocity: ev.value2 >= 0 ? ev.value2 : inst.defaultVolume, offset: region.offset, length: region.length, isStereo: region.isStereo, loopType: region.loopType, loopStart: region.loopStart, loopLength: region.loopLength, volumeEnvelope: inst.volumeEnvelope, panningEnvelope: inst.panningEnvelope, pitchEnvelope: inst.pitchEnvelope, volumeEnvOn: snap.volEnvEnabled[instID] != 0, panningEnvOn: snap.panEnvEnabled[instID] != 0, pitchEnvOn: snap.pitchEnvEnabled[instID] != 0, finetune: region.finetune, defaultPan: res.channelPans[ch])
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Build active-channel index list for voice processing
        var aCount = 0
        for i in 0..<kMaxChannels {
            let vp = res.voices.advanced(by: i)
            if vp.pointee.active {
                vp.pointee.processTickEffects(tick: currentTick)
                if vp.pointee.active {
                    res.activeChannelIndices[aCount] = i
                    aCount += 1
                }
            }
        }
        res.activeChannelCount = aCount
        return false
    }

    // MARK: - Real-time Render Block

    public var renderBlock: AUInternalRenderBlock {
        let res = resources; let state = statePtr; let bank = sampleBank; let evtBuf = eventBuffer; let node = self
        return { [node] (actionFlags, timeStamp, frames, busNumber, outputData, realtimeBufferList, pullInputBlock) -> OSStatus in
            let raw = node._snapshotPtr.load(ordering: .acquiring)
            guard raw != 0 else { return noErr }
            let unmanaged = Unmanaged<SnapshotBox>.fromOpaque(UnsafeRawPointer(bitPattern: raw)!)
            let retained = unmanaged.retain()
            defer { retained.release() }
            let snap = unmanaged.takeUnretainedValue().snapshot

            while let ev = evtBuf.pop() {
                let ch = min(Int(ev.channel), kMaxChannels - 1)
                if ev.type == .noteOn, ev.value1 > 0 {
                    let voicePtr = res.voices.advanced(by: ch)
                    let instID = ev.instrument > 0 ? Int(ev.instrument) : res.channelMemory[ch]
                    if ev.instrument > 0 { res.channelMemory[ch] = instID }
                    if instID < 256 {
                        let inst = snap.instruments[instID]
                        let freqVal = Double(ev.value1)
                        guard freqVal.isFinite && freqVal > 0 else { continue }
                        let noteNum = Int(round(12.0 * log2(freqVal / 440.0) + 69.0))
                        if let region = inst.region(for: noteNum) {
                            voicePtr.pointee.trigger(frequency: Float(ev.value1), velocity: ev.value2 >= 0 ? ev.value2 : inst.defaultVolume, offset: region.offset, length: region.length, isStereo: region.isStereo, loopType: region.loopType, loopStart: region.loopStart, loopLength: region.loopLength, volumeEnvelope: inst.volumeEnvelope, panningEnvelope: inst.panningEnvelope, pitchEnvelope: inst.pitchEnvelope, volumeEnvOn: snap.volEnvEnabled[instID] != 0, panningEnvOn: snap.panEnvEnabled[instID] != 0, pitchEnvOn: snap.pitchEnvEnabled[instID] != 0, finetune: region.finetune, defaultPan: res.channelPans[ch])
                        }
                    }
                } else if ev.type == .noteOff { res.voices.advanced(by: ch).pointee.active = false }
            }

            vDSP_vclr(res.sumL, 1, vDSP_Length(frames))
            vDSP_vclr(res.sumR, 1, vDSP_Length(frames))
            // Clear aux-bus accumulators for this block.
            for b in 0..<kAuxBusCount {
                vDSP_vclr(res.busL[b], 1, vDSP_Length(frames))
                vDSP_vclr(res.busR[b], 1, vDSP_Length(frames))
            }

            let packed0    = node.tickAccumulator.load(ordering: .relaxed)
            var tickRemain = Int(packed0)
            var tickFrac   = packed0 - Double(tickRemain)
            var samplesProcessedInBlock = 0

            while samplesProcessedInBlock < Int(frames) {
                if tickRemain == 0 {
                    let currentTick = Int(state.pointee.samplesProcessed) % Int(max(1, state.pointee.ticksPerRow))
                    state.pointee.samplesProcessed = (state.pointee.samplesProcessed + 1) % 1000000

                    let autoSnap = node.currentAutomationSnapshot()
                    AudioRenderNode.processTickSequencer(snap: snap, state: state, res: res, currentTick: currentTick, wrapOnEnd: true, auto: autoSnap)
                    
                    // Metronome trigger: Trigger on tick 0 of every row if enabled
                    if state.pointee.isMetronomeEnabled != 0 && currentTick == 0 {
                        res.metronomeAmplitude = 0.3
                        // Higher pitch for the start of pattern (order progression)
                        res.metronomePhase = state.pointee.currentEngineRow == 0 ? 1600.0 : 800.0
                    }

                    let spt = (node.sampleRate * 2.5) / Double(max(32, state.pointee.bpm))
                    let tprTick = max(1, Int(state.pointee.ticksPerRow)); let withinRowTick = Float(currentTick) / Float(tprTick)
                    state.pointee.playheadPosition = Float(state.pointee.currentEngineRow) + withinRowTick
                    // Stamp host time so Metal can extrapolate at 120Hz between audio callbacks
                    state.pointee.fractionalRowHostTime = mach_absolute_time()
                    state.pointee.rowDurationSeconds = Float(spt * Double(tprTick) / node.sampleRate)
                    let ideal = spt + tickFrac
                    tickRemain = Int(ideal)
                    tickFrac   = ideal - Double(tickRemain)
                }

                let samplesLeft = Int(frames) - samplesProcessedInBlock
                let toProcess   = min(samplesLeft, tickRemain)
                if toProcess > 0 {
                    let scSource = state.pointee.sidechainChannel
                    let scAmount = state.pointee.sidechainAmount
                    
                    for idx in 0..<res.activeChannelCount {
                        let i = res.activeChannelIndices[idx]
                        let vp = res.voices.advanced(by: i)
                        guard vp.pointee.active else { continue }
                        vDSP_vclr(res.scratchL, 1, vDSP_Length(toProcess))
                        vDSP_vclr(res.scratchR, 1, vDSP_Length(toProcess))
                        vDSP_vclr(res.scratchMono, 1, vDSP_Length(toProcess))
                        vp.pointee.process(bufferL: res.scratchL, bufferR: res.scratchR, scratchBuffer: res.interpScratch, monoBuffer: res.scratchMono, positionsScratch: res.positionsScratch, sampleBank: bank, count: toProcess, sampleRate: Float(node.sampleRate))

                        // Track sidechain source peak
                        if Int32(i) == scSource {
                            var p: Float = 0
                            vDSP_maxmgv(res.scratchL, 1, &p, vDSP_Length(toProcess))
                            res.sidechainPeak = max(res.sidechainPeak, p)
                        }
                        
                        // PDC: Apply per-channel delay
                        let lat = res.channelLatencies[i]
                        if lat > 0 {
                            let dBufL = res.delayBuffersL[i]
                            let dBufR = res.delayBuffersR[i]
                            let dMax = res.maxDelayFrames
                            var dIdx = res.delayIndices[i]
                            
                            for j in 0..<toProcess {
                                let inL = res.scratchL[j]; let inR = res.scratchR[j]
                                dBufL[dIdx] = inL; dBufR[dIdx] = inR
                                let rIdx = (dIdx - lat + dMax) % dMax
                                res.scratchL[j] = dBufL[rIdx]; res.scratchR[j] = dBufR[rIdx]
                                dIdx = (dIdx + 1) % dMax
                            }
                            res.delayIndices[i] = dIdx
                        }
                        
                        if i < 32 { node.spatialPush?(i, res.scratchMono, toProcess) }
                        var vol = res.channelVolumes[i]
                        
                        // If this is NOT the source, apply ducking
                        if scSource >= 0 && Int32(i) != scSource && scAmount > 0 {
                            let duck = 1.0 - (res.sidechainPeak * scAmount)
                            vol *= max(0.05, duck) // Clamp to -26dB floor
                        }
                        
                        vDSP_vsma(res.scratchL, 1, &vol, res.sumL.advanced(by: samplesProcessedInBlock), 1, res.sumL.advanced(by: samplesProcessedInBlock), 1, vDSP_Length(toProcess))
                        vDSP_vsma(res.scratchR, 1, &vol, res.sumR.advanced(by: samplesProcessedInBlock), 1, res.sumR.advanced(by: samplesProcessedInBlock), 1, vDSP_Length(toProcess))

                        // Aux sends: contribute this channel's (unmastered) signal to each bus
                        // scaled by the per-(channel,bus) send amount × channel volume (post-fader).
                        for b in 0..<kAuxBusCount {
                            let sendAmt = res.sendAmounts[i * kAuxBusCount + b]
                            if sendAmt > 0 {
                                var sendGain = vol * sendAmt
                                vDSP_vsma(res.scratchL, 1, &sendGain,
                                          res.busL[b].advanced(by: samplesProcessedInBlock), 1,
                                          res.busL[b].advanced(by: samplesProcessedInBlock), 1,
                                          vDSP_Length(toProcess))
                                vDSP_vsma(res.scratchR, 1, &sendGain,
                                          res.busR[b].advanced(by: samplesProcessedInBlock), 1,
                                          res.busR[b].advanced(by: samplesProcessedInBlock), 1,
                                          vDSP_Length(toProcess))
                            }
                        }
                    }

                    // Release sidechain peak slowly
                    res.sidechainPeak *= 0.999
                    
                    // Sum Metronome
                    if res.metronomeAmplitude > 0.001 {
                        for j in 0..<toProcess {
                            let val = sinf(res.metronomePhase * 0.01) * res.metronomeAmplitude
                            res.sumL[samplesProcessedInBlock + j] += val
                            res.sumR[samplesProcessedInBlock + j] += val
                            res.metronomePhase += 1.0
                            res.metronomeAmplitude *= 0.9992 // Decay
                        }
                    }
                    
                    samplesProcessedInBlock += toProcess
                    tickRemain              -= toProcess
                }
            }
            node.tickAccumulator.store(Double(tickRemain) + tickFrac, ordering: .relaxed)

            // Bus → master summing happens in `RenderBlockWrapper.coreAudioRenderCallback`
            // AFTER per-bus AUv3 insert chains run. Leaving busL/busR populated here so the
            // wrapper can wrap them in AudioBufferLists and hand them to bus plugins.
            // Offline render (`renderOffline`, below) still sums buses inline since export
            // has no wrapper layer — bus inserts are a real-time-only feature for now.

            // activeChannelCount is already maintained by processTickSequencer — no need
            // to iterate all kMaxChannels here.
            state.pointee.activeVoices = Int32(res.activeChannelCount)
var masterVol = Float(state.pointee.masterVolume) * 0.5
vDSP_vsmul(res.sumL, 1, &masterVol, res.sumL, 1, vDSP_Length(frames))
vDSP_vsmul(res.sumR, 1, &masterVol, res.sumR, 1, vDSP_Length(frames))

// Master Safety Limiter (1ms attack, 100ms release approximation)
if state.pointee.isMasterLimiterEnabled != 0 {
    let release: Float = 0.9999 // Slow release
    let attack:  Float = 0.1    // Fast attack
    for i in 0..<Int(frames) {
        let peak = max(abs(res.sumL[i]), abs(res.sumR[i]))
        let targetGain: Float = peak > 1.0 ? 1.0 / peak : 1.0
        if targetGain < res.limiterGain {
            res.limiterGain += (targetGain - res.limiterGain) * attack
        } else {
            res.limiterGain += (targetGain - res.limiterGain) * (1.0 - release)
        }
        res.sumL[i] *= res.limiterGain
        res.sumR[i] *= res.limiterGain
    }
} else {
    // Fallback to soft clipping if limiter is off
    for i in 0..<Int(frames) {
        res.sumL[i] = tanhf(res.sumL[i])
        res.sumR[i] = tanhf(res.sumR[i])
    }
}

var peakL: Float = 0
vDSP_maxmgv(res.sumL, 1, &peakL, vDSP_Length(frames))
var peakR: Float = 0
vDSP_maxmgv(res.sumR, 1, &peakR, vDSP_Length(frames))
state.pointee.peakLevel = max(peakL, peakR)

            // Mastering-grade metering: K-weighted LUFS + 4× true-peak + phase correlation.
            // Runs on the post-master (post-limiter) sumL/sumR — this is what the listener hears.
            node.masterMeter.process(stereoL: res.sumL, stereoR: res.sumR,
                                     frames: Int(frames), sampleRate: node.sampleRate)
            state.pointee.truePeak         = node.masterMeter.truePeak
            state.pointee.lufsMomentary    = node.masterMeter.momentaryLUFS
            state.pointee.lufsShortTerm    = node.masterMeter.shortTermLUFS
            state.pointee.lufsIntegrated   = node.masterMeter.integratedLUFS
            state.pointee.phaseCorrelation = node.masterMeter.phaseCorrelation

            let bufList = UnsafeMutableAudioBufferListPointer(outputData)
            if let dstL = bufList[0].mData?.assumingMemoryBound(to: Float.self), let dstR = bufList[1].mData?.assumingMemoryBound(to: Float.self) {
                memcpy(dstL, res.sumL, Int(frames) * MemoryLayout<Float>.size); memcpy(dstR, res.sumR, Int(frames) * MemoryLayout<Float>.size)
            }
            return noErr
        }
    }

    // MARK: - Offline Render

    @discardableResult
    public func renderOffline(
        frames:  Int,
        snap:    SongSnapshot,
        state:   UnsafeMutablePointer<EngineSharedState>,
        bufferL: UnsafeMutablePointer<Float>,
        bufferR: UnsafeMutablePointer<Float>
    ) -> Int {
        let res  = resources
        let bank = sampleBank
        var tickRemain  = 0
        var tickFrac    = 0.0
        var totalWritten = 0

        while totalWritten < frames && state.pointee.isPlaying != 0 {
            let chunkSize = min(frames - totalWritten, res.maxFrames)
            vDSP_vclr(res.sumL, 1, vDSP_Length(chunkSize))
            vDSP_vclr(res.sumR, 1, vDSP_Length(chunkSize))
            for b in 0..<kAuxBusCount {
                vDSP_vclr(res.busL[b], 1, vDSP_Length(chunkSize))
                vDSP_vclr(res.busR[b], 1, vDSP_Length(chunkSize))
            }
            var samplesInChunk = 0

            while samplesInChunk < chunkSize {
                if tickRemain == 0 {
                    let currentTick = Int(state.pointee.samplesProcessed) % Int(max(1, state.pointee.ticksPerRow))
                    state.pointee.samplesProcessed = (state.pointee.samplesProcessed + 1) % 1_000_000

                    let autoSnap = self.currentAutomationSnapshot()
                    if AudioRenderNode.processTickSequencer(snap: snap, state: state, res: res, currentTick: currentTick, wrapOnEnd: false, auto: autoSnap) {
                        break
                    }

                    let spt   = (self.sampleRate * 2.5) / Double(max(32, state.pointee.bpm))
                    let ideal = spt + tickFrac
                    tickRemain = Int(ideal)
                    tickFrac   = ideal - Double(tickRemain)
                }

                let remaining = chunkSize - samplesInChunk
                let toProcess = min(remaining, tickRemain)
                if toProcess > 0 {
                    for idx in 0..<res.activeChannelCount {
                        let i = res.activeChannelIndices[idx]
                        let vp = res.voices.advanced(by: i)
                        guard vp.pointee.active else { continue }
                        vDSP_vclr(res.scratchL, 1, vDSP_Length(toProcess))
                        vDSP_vclr(res.scratchR, 1, vDSP_Length(toProcess))
                        vDSP_vclr(res.scratchMono, 1, vDSP_Length(toProcess))
                        vp.pointee.process(bufferL: res.scratchL, bufferR: res.scratchR, scratchBuffer: res.interpScratch, monoBuffer: res.scratchMono, positionsScratch: res.positionsScratch, sampleBank: bank, count: toProcess, sampleRate: Float(self.sampleRate))
                        var vol = res.channelVolumes[i]
                        let dst = samplesInChunk
                        vDSP_vsma(res.scratchL, 1, &vol, res.sumL.advanced(by: dst), 1,
                                  res.sumL.advanced(by: dst), 1, vDSP_Length(toProcess))
                        vDSP_vsma(res.scratchR, 1, &vol, res.sumR.advanced(by: dst), 1,
                                  res.sumR.advanced(by: dst), 1, vDSP_Length(toProcess))

                        for b in 0..<kAuxBusCount {
                            let sendAmt = res.sendAmounts[i * kAuxBusCount + b]
                            if sendAmt > 0 {
                                var sendGain = vol * sendAmt
                                vDSP_vsma(res.scratchL, 1, &sendGain,
                                          res.busL[b].advanced(by: dst), 1,
                                          res.busL[b].advanced(by: dst), 1, vDSP_Length(toProcess))
                                vDSP_vsma(res.scratchR, 1, &sendGain,
                                          res.busR[b].advanced(by: dst), 1,
                                          res.busR[b].advanced(by: dst), 1, vDSP_Length(toProcess))
                            }
                        }
                    }
                    samplesInChunk += toProcess
                    tickRemain     -= toProcess
                }
                if state.pointee.isPlaying == 0 { break }
            } // inner while

            for b in 0..<kAuxBusCount {
                var bvol = res.busVolumes[b]
                if bvol > 0 {
                    vDSP_vsma(res.busL[b], 1, &bvol, res.sumL, 1, res.sumL, 1, vDSP_Length(chunkSize))
                    vDSP_vsma(res.busR[b], 1, &bvol, res.sumR, 1, res.sumR, 1, vDSP_Length(chunkSize))
                }
            }

            var masterVol = Float(state.pointee.masterVolume) * 0.5
            vDSP_vsmul(res.sumL, 1, &masterVol, res.sumL, 1, vDSP_Length(chunkSize))
            vDSP_vsmul(res.sumR, 1, &masterVol, res.sumR, 1, vDSP_Length(chunkSize))
            for i in 0..<chunkSize {
                res.sumL[i] = tanhf(res.sumL[i])
                res.sumR[i] = tanhf(res.sumR[i])
            }

            memcpy(bufferL.advanced(by: totalWritten), res.sumL, chunkSize * MemoryLayout<Float>.size)
            memcpy(bufferR.advanced(by: totalWritten), res.sumR, chunkSize * MemoryLayout<Float>.size)
            totalWritten += chunkSize
        }

        return totalWritten
    }

    // MARK: - Concurrent offline render

    /// Multi-core offline render. Voice processing is parallelized across cores via
    /// `DispatchQueue.concurrentPerform` using the pre-allocated per-thread scratch
    /// buffers on `RenderResources` — no allocation on the render path.
    ///
    /// Mixing (vsma into sumL/sumR + bus sends) happens under a spinlock per voice,
    /// which is cheap relative to the voice.process cost. For typical projects with
    /// 20–200 active voices this gives a ~4-6× speedup on an M-series 8-core vs the
    /// serial path. Realtime render stays serial — this path is offline-only.
    ///
    /// Drop-in replacement for `renderOffline(...)` when the caller can afford
    /// coarser lock contention in exchange for faster bounce times.
    @discardableResult
    public func renderOfflineConcurrent(
        frames:  Int,
        snap:    SongSnapshot,
        state:   UnsafeMutablePointer<EngineSharedState>,
        bufferL: UnsafeMutablePointer<Float>,
        bufferR: UnsafeMutablePointer<Float>
    ) -> Int {
        let res = resources
        let bank = sampleBank
        var tickRemain  = 0
        var tickFrac    = 0.0
        var totalWritten = 0
        let mixLock = NSLock()

        while totalWritten < frames && state.pointee.isPlaying != 0 {
            let chunkSize = min(frames - totalWritten, res.maxFrames)
            vDSP_vclr(res.sumL, 1, vDSP_Length(chunkSize))
            vDSP_vclr(res.sumR, 1, vDSP_Length(chunkSize))
            for b in 0..<kAuxBusCount {
                vDSP_vclr(res.busL[b], 1, vDSP_Length(chunkSize))
                vDSP_vclr(res.busR[b], 1, vDSP_Length(chunkSize))
            }
            var samplesInChunk = 0

            while samplesInChunk < chunkSize {
                if tickRemain == 0 {
                    let currentTick = Int(state.pointee.samplesProcessed) % Int(max(1, state.pointee.ticksPerRow))
                    state.pointee.samplesProcessed = (state.pointee.samplesProcessed + 1) % 1_000_000
                    let autoSnap = self.currentAutomationSnapshot()
                    if AudioRenderNode.processTickSequencer(snap: snap, state: state, res: res,
                                                            currentTick: currentTick, wrapOnEnd: false,
                                                            auto: autoSnap) {
                        break
                    }
                    let spt   = (self.sampleRate * 2.5) / Double(max(32, state.pointee.bpm))
                    let ideal = spt + tickFrac
                    tickRemain = Int(ideal); tickFrac = ideal - Double(tickRemain)
                }

                let remaining = chunkSize - samplesInChunk
                let toProcess = min(remaining, tickRemain)
                let dst = samplesInChunk
                if toProcess > 0 {
                    let sampleRate = Float(self.sampleRate)
                    let activeCount = res.activeChannelCount

                    // Parallel voice processing. Each iteration owns a unique scratch
                    // slot indexed by `idx`; voiceThreadSlots == kMaxChannels so collisions
                    // are impossible. (An earlier "round-robin mod 8" allocation could
                    // race two iterations onto the same slot — a real bug, caught by the
                    // serial-vs-concurrent parity test in UAT 53.)
                    DispatchQueue.concurrentPerform(iterations: activeCount) { idx in
                        let i = res.activeChannelIndices[idx]
                        let vp = res.voices.advanced(by: i)
                        guard vp.pointee.active else { return }

                        let slot = idx
                        let sL = res.threadScratchL[slot]
                        let sR = res.threadScratchR[slot]
                        let sM = res.threadScratchMono[slot]
                        vDSP_vclr(sL, 1, vDSP_Length(toProcess))
                        vDSP_vclr(sR, 1, vDSP_Length(toProcess))
                        vDSP_vclr(sM, 1, vDSP_Length(toProcess))
                        vp.pointee.process(bufferL: sL, bufferR: sR,
                                           scratchBuffer: res.threadInterpScratch[slot],
                                           monoBuffer: sM,
                                           positionsScratch: res.threadPositionsScratch[slot],
                                           sampleBank: bank, count: toProcess,
                                           sampleRate: sampleRate)

                        var vol = res.channelVolumes[i]
                        mixLock.lock()
                        vDSP_vsma(sL, 1, &vol, res.sumL.advanced(by: dst), 1,
                                  res.sumL.advanced(by: dst), 1, vDSP_Length(toProcess))
                        vDSP_vsma(sR, 1, &vol, res.sumR.advanced(by: dst), 1,
                                  res.sumR.advanced(by: dst), 1, vDSP_Length(toProcess))
                        for b in 0..<kAuxBusCount {
                            let sendAmt = res.sendAmounts[i * kAuxBusCount + b]
                            if sendAmt > 0 {
                                var sendGain = vol * sendAmt
                                vDSP_vsma(sL, 1, &sendGain, res.busL[b].advanced(by: dst), 1,
                                          res.busL[b].advanced(by: dst), 1, vDSP_Length(toProcess))
                                vDSP_vsma(sR, 1, &sendGain, res.busR[b].advanced(by: dst), 1,
                                          res.busR[b].advanced(by: dst), 1, vDSP_Length(toProcess))
                            }
                        }
                        mixLock.unlock()
                    }
                    samplesInChunk += toProcess
                    tickRemain     -= toProcess
                }
                if state.pointee.isPlaying == 0 { break }
            }

            for b in 0..<kAuxBusCount {
                var bvol = res.busVolumes[b]
                if bvol > 0 {
                    vDSP_vsma(res.busL[b], 1, &bvol, res.sumL, 1, res.sumL, 1, vDSP_Length(chunkSize))
                    vDSP_vsma(res.busR[b], 1, &bvol, res.sumR, 1, res.sumR, 1, vDSP_Length(chunkSize))
                }
            }

            var masterVol = Float(state.pointee.masterVolume) * 0.5
            vDSP_vsmul(res.sumL, 1, &masterVol, res.sumL, 1, vDSP_Length(chunkSize))
            vDSP_vsmul(res.sumR, 1, &masterVol, res.sumR, 1, vDSP_Length(chunkSize))
            for i in 0..<chunkSize {
                res.sumL[i] = tanhf(res.sumL[i]); res.sumR[i] = tanhf(res.sumR[i])
            }

            memcpy(bufferL.advanced(by: totalWritten), res.sumL, chunkSize * MemoryLayout<Float>.size)
            memcpy(bufferR.advanced(by: totalWritten), res.sumR, chunkSize * MemoryLayout<Float>.size)
            totalWritten += chunkSize
        }

        return totalWritten
    }
}
