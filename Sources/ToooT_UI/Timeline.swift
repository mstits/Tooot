/*
 *  NextGenTracker (LegacyTracker 2026)
 *  Copyright (c) 2026. All rights reserved.
 *
 *  Timeline — UI sync loop and transport controller.
 *
 *  Concurrency contract:
 *    • All methods are @MainActor.
 *    • sequencerSnapshot.didSet no longer writes to AudioEngine.songData directly
 *      (that was the data race).  Instead it calls renderNode.swapSnapshot(), which
 *      does a single atomic pointer exchange — safe from any thread.
 *    • syncEngineToUI() reads from sharedStatePtr (a plain C struct of Int32/Float),
 *      which are naturally atomic on arm64 aligned word stores.
 */

import Foundation
import ToooT_Core
import ToooT_Plugins
import SwiftUI
import Combine

private final class TimerContainer: @unchecked Sendable {
    var cancellable: AnyCancellable?
    func invalidate() { cancellable?.cancel(); cancellable = nil }
}

@MainActor
public final class Timeline {
    private let state: PlaybackState
    internal weak var audioEngine: AudioEngine?
    internal weak var renderNode:   AudioRenderNode?   // for atomic snapshot swap
    public let hostManager = AUv3HostManager()
    private let timerContainer = TimerContainer()
    private var lastBPM: Int = 0

    /// Set by ProjectToooTApp on launch; fired every 60 s of real time to write
    /// an autosave snapshot. Decoupled from the 30 Hz UI sync loop so the
    /// MADWriter IO cost never lands on a rendering frame.
    public var onAutosaveTick: (() -> Void)?

    /// Called when BPM changes mid-playback so the host can update the MIDI clock rate.
    public var onBPMChange: ((Int) -> Void)?

    private var lastAutosaveTime: TimeInterval = Date().timeIntervalSinceReferenceDate

    public init(state: PlaybackState, engine: AudioEngine, renderNode: AudioRenderNode? = nil) {
        self.state      = state
        self.audioEngine = engine
        self.renderNode  = renderNode

        // UI state throttling: Pipeline published engine metrics through Combine throttle
        timerContainer.cancellable = Timer.publish(every: 0.016, on: .main, in: .common)
            .autoconnect()
            .throttle(for: .seconds(0.033), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self else { return }
                self.syncEngineToUI()

                // Autosave cadence: 60 s of wall-clock time.
                let now = Date().timeIntervalSinceReferenceDate
                if now - self.lastAutosaveTime >= 60.0 {
                    self.lastAutosaveTime = now
                    self.onAutosaveTick?()
                }
            }
    }

    deinit { timerContainer.invalidate() }

    // MARK: - Transport

    public func play() {
        guard let engine = audioEngine else { return }
        renderNode?.resetForPlayback()
        state.isPlaying = true
        engine.sharedStatePtr.pointee.isPlaying = 1
    }

    public func stop() {
        state.isPlaying = false
        if let engine = audioEngine {
            engine.sharedStatePtr.pointee.isPlaying         = 0
            engine.sharedStatePtr.pointee.currentEngineRow  = 0
            engine.sharedStatePtr.pointee.currentOrder      = 0
            engine.sharedStatePtr.pointee.samplesProcessed  = 0
            // Don't reset currentPattern — preserve user's editing position
        }
        state.currentEngineRow = 0
        state.currentUIRow     = 0
        state.currentOrder     = 0
        // Note: intentionally NOT resetting currentPattern so user stays on editing position
    }

    // MARK: - Snapshot publishing

    /// Atomically hands the current sequencer + instrument data to the render thread.
    /// Called whenever sequencerSnapshot or any instrument changes.
    public func publishSnapshot() {
        // Sync UI dict to RT slab before publishing (safe to index 0...255)
        for (id, inst) in state.instruments {
            if id >= 0 && id < 256 {
                state.instrumentBank[id] = inst
            }
        }

        renderNode?.swapSnapshot(SongSnapshot(
            events:      state.sequencerData.events,
            instruments: state.instrumentBank,
            orderList:   state.orderList,
            songLength:  state.songLength,
            volEnv:      state.volEnvEnabledPtr,
            panEnv:      state.panEnvEnabledPtr,
            pitchEnv:    state.pitchEnvEnabledPtr))

        // PlaybackState.automationLanes is the legacy UI Bezier representation in
        // Helpers.swift; convert to the Core lane type that the render evaluator
        // consumes. parameter → targetID, time → beat, value → Float, controlPoint
        // origin → linear (anything else → sCurve).
        var perChannel: [Int: [ToooT_Core.AutomationLane]] = [:]
        for (ch, uiLanes) in state.automationLanes {
            perChannel[ch] = uiLanes.map { ui -> ToooT_Core.AutomationLane in
                var core = ToooT_Core.AutomationLane(targetID: ui.parameter)
                for p in ui.points {
                    core.setPoint(beat: p.time, value: Float(p.value),
                                  curveOut: p.controlPoint == .zero ? .linear : .sCurve)
                }
                return core
            }
        }
        renderNode?.swapAutomationSnapshot(AutomationSnapshot.build(from: perChannel))
    }
    
    // MARK: - Tempo Overrides
    
    public func setBPM(_ bpm: Int) {
        state.bpm = bpm
        if let engine = audioEngine {
            engine.sharedStatePtr.pointee.bpm = Int32(bpm)
        }
        if bpm != lastBPM {
            lastBPM = bpm
            onBPMChange?(bpm)
        }
    }
    
    public func setTicksPerRow(_ ticks: Int) {
        state.ticksPerRow = ticks
        if let engine = audioEngine {
            engine.sharedStatePtr.pointee.ticksPerRow = Int32(ticks)
        }
    }

    // MARK: - UI sync (30 Hz poll)

    private func syncEngineToUI() {
        renderNode?.processDeallocations()
        guard let engine = audioEngine else { return }

        // ── Push UI values → engine shared state ────────────────────────────
        engine.sharedStatePtr.pointee.masterVolume        = Float(state.masterVolume)
        engine.sharedStatePtr.pointee.isStereoWideEnabled = state.isStereoWideEnabled ? 1 : 0
        engine.sharedStatePtr.pointee.isReverbEnabled     = state.isReverbEnabled ? 1 : 0
        engine.sharedStatePtr.pointee.isMetronomeEnabled  = state.isMetronomeEnabled ? 1 : 0
        engine.sharedStatePtr.pointee.isMasterLimiterEnabled = state.isMasterLimiterEnabled ? 1 : 0
        engine.sharedStatePtr.pointee.sidechainChannel = Int32(state.sidechainChannel)
        engine.sharedStatePtr.pointee.sidechainAmount = state.sidechainAmount
        if !state.isPlaying {
            // Only push UI values when stopped — engine owns these during playback
            engine.sharedStatePtr.pointee.bpm         = Int32(state.bpm)
            engine.sharedStatePtr.pointee.ticksPerRow = Int32(state.ticksPerRow)
        } else {
            // Read engine values back so UI reflects in-song tempo changes
            let eb = Int(engine.sharedStatePtr.pointee.bpm)
            if state.bpm != eb { state.bpm = eb }
            let et = Int(engine.sharedStatePtr.pointee.ticksPerRow)
            if state.ticksPerRow != et { state.ticksPerRow = et }
            if state.bpm != lastBPM { lastBPM = state.bpm; onBPMChange?(state.bpm) }
        }

        // ── Pull atomic values ← engine shared state ─────────────────────────
        let es = engine.sharedStatePtr.pointee
        
        // Only update observable properties if they've actually changed to minimize AttributeGraph pressure
        if state.currentOrder != Int(es.currentOrder) { state.currentOrder = Int(es.currentOrder) }
        if state.currentEngineRow != Int(es.currentEngineRow) { state.currentEngineRow = Int(es.currentEngineRow) }
        // Only sync pattern from engine during playback — don't clobber manual Tab navigation
        if state.isPlaying && Int(es.currentPattern) != state.currentPattern {
            state.currentPattern = Int(es.currentPattern)
            state.textureInvalidationTrigger += 1
        }
        
        // Threshold guards: avoid invalidating @Observable observers when values haven't meaningfully changed.
        let newPeak = es.peakLevel
        if abs(state.peakLevel - newPeak) > 0.01 { state.peakLevel = newPeak }
        let newVox = Int(es.activeVoices)
        if state.activeVoices != newVox { state.activeVoices = newVox }

        let pos     = es.playheadPosition
        let newFrac = pos.isFinite ? max(0, min(1, pos - Float(Int(pos)))) : 0
        if abs(state.fractionalRow - newFrac) > 0.001 {
            state.fractionalRow = newFrac
        }

        if state.currentUIRow != state.currentEngineRow {
            state.currentUIRow = state.currentEngineRow
        }

        // algSeed: poll each row boundary and update so NeuralIntelligenceView can react
        let newSeed = es.algSeed
        if state.algSeed != newSeed { state.algSeed = newSeed }

        // ── Automation & Mute/Solo matrix ──────────────────────────────────────
        // Writes go directly to engine pointers — zero SwiftUI overhead.
        let patternPos = Double(state.currentEngineRow) / 64.0 + Double(newFrac) / 64.0
        let anySolo = state.anySolo

        // Only iterate channels with active automation (avoids kMaxChannels dict lookups when empty).
        for (i, lanes) in state.automationLanes {
            for lane in lanes {
                let v = Float(lane.evaluate(at: patternPos))
                if lane.parameter == "Volume"  { state.channelVolumesPtr[i] = v }
                else if lane.parameter == "Panning" { state.channelPansPtr[i] = v }
            }
        }

        // Volume/pan/MIDI pointer writes.
        if let node = renderNode {
            for i in 0..<kMaxChannels {
                let muted = (state.channelMutesPtr[i] != 0) || (anySolo && state.channelSolosPtr[i] == 0)
                node.channelVolumesPtr[i]  = muted ? 0.0 : state.channelVolumesPtr[i]
                node.channelPansPtr[i]     = state.channelPansPtr[i]
                node.midiEnabledPtr[i]     = state.midiChannelsPtr[i]
            }
        }
    }
}
