/*
 *  PROJECT ToooT (ToooT_Core)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  Enterprise-grade AUv3 Hosting and Hardware Routing.
 *
 *  AudioRenderNode integration:
 *    • AudioRenderNode.renderBlock replaces AudioEngine.internalRenderBlock
 *      as the CoreAudio callback — eliminating the SongData data race.
 *    • AudioEngine is still registered as an AUAudioUnit (required for AUv3 hosting),
 *      and its sharedStatePtr is shared with AudioRenderNode (single source of truth
 *      for playback counters, master volume, mute flags etc.).
 *    • swapSnapshot() is the ONLY legal way to update song data during playback.
 */

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import CoreMIDI
import Accelerate
import os.log
import ToooT_Core
import ToooT_Plugins
import ToooT_IO
import ToooT_VST3
import ToooT_CLAP

private let hostLog = Logger(subsystem: "com.apple.ProjectToooT", category: "AudioHost")

// MARK: - Render callback wrapper (lives on the CoreAudio real-time thread)

private final class RenderBlockWrapper: @unchecked Sendable {
    // engineBlock is now AudioRenderNode.renderBlock — race-free.
    let engineBlock:    AUInternalRenderBlock
    let stereoWideBlock: AUInternalRenderBlock?
    let reverbBlock:    AUInternalRenderBlock?
    let masterEQBlock:   AUInternalRenderBlock?
    let statePtr:       UnsafeMutablePointer<EngineSharedState>
    let renderResources: RenderResources  // access to bus buffers + bus volumes

    // Per-channel AUv3 insert chains and instruments.
    // We use a fixed-size array of pointers to blocks to ensure RT-safety.
    // kMaxChannels channels, max 4 plugins per channel + 1 instrument.
    nonisolated(unsafe) let pluginBlocks: UnsafeMutablePointer<AUInternalRenderBlock?>
    nonisolated(unsafe) let instrumentBlocks: UnsafeMutablePointer<AUInternalRenderBlock?>
    nonisolated(unsafe) let pluginCounts: UnsafeMutablePointer<Int32>

    // Per-bus AUv3 insert chains. Up to 4 slots per bus. The insert block reads + writes
    // the bus buffer via a pre-allocated AudioBufferList hand-crafted to point at
    // `res.busL[b]` / `res.busR[b]`. After the whole bus chain runs, the wrapper sums
    // the (now-processed) bus buffers into the master ioData.
    nonisolated(unsafe) let busInsertBlocks: UnsafeMutablePointer<AUInternalRenderBlock?>  // kAuxBusCount * 4
    nonisolated(unsafe) let busPluginCounts: UnsafeMutablePointer<Int32>                    // kAuxBusCount
    nonisolated(unsafe) let busBufferLists:  [UnsafeMutableAudioBufferListPointer]          // one per bus

    init(engineBlock:    @escaping AUInternalRenderBlock,
         stereoWideBlock: AUInternalRenderBlock?,
         reverbBlock:    AUInternalRenderBlock?,
         masterEQBlock:   AUInternalRenderBlock?,
         statePtr:       UnsafeMutablePointer<EngineSharedState>,
         renderResources: RenderResources) {
        self.engineBlock     = engineBlock
        self.stereoWideBlock = stereoWideBlock
        self.reverbBlock     = reverbBlock
        self.masterEQBlock   = masterEQBlock
        self.statePtr        = statePtr
        self.renderResources = renderResources

        self.pluginBlocks = .allocate(capacity: kMaxChannels * 4)
        self.pluginBlocks.initialize(repeating: nil, count: kMaxChannels * 4)
        self.instrumentBlocks = .allocate(capacity: kMaxChannels)
        self.instrumentBlocks.initialize(repeating: nil, count: kMaxChannels)
        self.pluginCounts = .allocate(capacity: kMaxChannels)
        self.pluginCounts.initialize(repeating: 0, count: kMaxChannels)

        self.busInsertBlocks = .allocate(capacity: kAuxBusCount * 4)
        self.busInsertBlocks.initialize(repeating: nil, count: kAuxBusCount * 4)
        self.busPluginCounts = .allocate(capacity: kAuxBusCount)
        self.busPluginCounts.initialize(repeating: 0, count: kAuxBusCount)

        // Pre-allocate one 2-buffer AudioBufferList per bus. The mData pointers are set
        // once at init (they never move — res.busL[b] is stable for the life of the
        // RenderResources). Only mDataByteSize needs to change per render call.
        var lists: [UnsafeMutableAudioBufferListPointer] = []
        for b in 0..<kAuxBusCount {
            let abl = AudioBufferList.allocate(maximumBuffers: 2)
            abl[0] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize:   0,
                mData:           UnsafeMutableRawPointer(renderResources.busL[b]))
            abl[1] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize:   0,
                mData:           UnsafeMutableRawPointer(renderResources.busR[b]))
            lists.append(abl)
        }
        self.busBufferLists = lists
    }

    deinit {
        pluginBlocks.deallocate()
        instrumentBlocks.deallocate()
        pluginCounts.deallocate()
        busInsertBlocks.deallocate()
        busPluginCounts.deallocate()
        for abl in busBufferLists { free(abl.unsafeMutablePointer) }
    }
}

private func coreAudioRenderCallback(
    inRefCon:       UnsafeMutableRawPointer,
    ioActionFlags:  UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp:    UnsafePointer<AudioTimeStamp>,
    inBusNumber:    UInt32,
    inNumberFrames: UInt32,
    ioData:         UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let wrapper = Unmanaged<RenderBlockWrapper>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let ioData else { return noErr }

    // 1. Tracker engine (now via AudioRenderNode — lock-free snapshot, Float-only pipeline)
    _ = wrapper.engineBlock(ioActionFlags, inTimeStamp, inNumberFrames, 0, ioData, nil, nil)

    // 2. Per-channel AUv3 chains (RT-safe loop)
    for ch in 0..<kMaxChannels {
        // If an external instrument is loaded for this channel, render it.
        if let instBlock = wrapper.instrumentBlocks[ch] {
            _ = instBlock(ioActionFlags, inTimeStamp, inNumberFrames, 0, ioData, nil, nil)
        }
        
        let count = wrapper.pluginCounts[ch]
        for p in 0..<Int(count) {
            if let block = wrapper.pluginBlocks[ch * 4 + p] {
                _ = block(ioActionFlags, inTimeStamp, inNumberFrames, 0, ioData, nil, nil)
            }
        }
    }

    // 3. Per-bus AUv3 insert chains + sum buses into master.
    //
    // Engine block left res.busL/busR populated but did NOT sum them into sumL/sumR.
    // Here we (a) run each bus's insert chain in place on its bus buffer, then
    // (b) sum the processed bus buffer into the master ioData scaled by busVolumes[b].
    let res = wrapper.renderResources
    let frames = Int(inNumberFrames)
    let byteSize = UInt32(frames * MemoryLayout<Float>.size)
    for b in 0..<kAuxBusCount {
        let count = wrapper.busPluginCounts[b]
        if count > 0 {
            let abl = wrapper.busBufferLists[b]
            abl[0].mDataByteSize = byteSize
            abl[1].mDataByteSize = byteSize
            for p in 0..<Int(count) {
                if let block = wrapper.busInsertBlocks[b * 4 + p] {
                    _ = block(ioActionFlags, inTimeStamp, inNumberFrames, 0,
                              abl.unsafeMutablePointer, nil, nil)
                }
            }
        }
        // Sum (possibly-processed) bus into master.
        var bvol = res.busVolumes[b]
        if bvol > 0 {
            let ablOut = UnsafeMutableAudioBufferListPointer(ioData)
            if ablOut.count >= 2,
               let masterL = ablOut[0].mData?.assumingMemoryBound(to: Float.self),
               let masterR = ablOut[1].mData?.assumingMemoryBound(to: Float.self) {
                vDSP_vsma(res.busL[b], 1, &bvol, masterL, 1, masterL, 1, vDSP_Length(frames))
                vDSP_vsma(res.busR[b], 1, &bvol, masterR, 1, masterR, 1, vDSP_Length(frames))
            }
        }
    }

    // 4. Internal vDSP effects.
    //    Order matters: EQ first (clean tonal shaping before any spatial /
    //    reverb processing), then stereo widening, then reverb tail.
    if wrapper.statePtr.pointee.isMasterEQEnabled != 0, let eq = wrapper.masterEQBlock {
        _ = eq(ioActionFlags, inTimeStamp, inNumberFrames, 0, ioData, nil, nil)
    }
    if wrapper.statePtr.pointee.isStereoWideEnabled != 0, let sw = wrapper.stereoWideBlock {
        _ = sw(ioActionFlags, inTimeStamp, inNumberFrames, 0, ioData, nil, nil)
    }
    if wrapper.statePtr.pointee.isReverbEnabled != 0, let rv = wrapper.reverbBlock {
        _ = rv(ioActionFlags, inTimeStamp, inNumberFrames, 0, ioData, nil, nil)
    }
    return noErr
}

// MARK: - AudioHost

@MainActor
public final class AudioHost {
    public var trackerAU: AudioEngine?
    public var renderNode: AudioRenderNode?           // owns the render block & snapshot
    public var spatialManager: SpatialManager         // initialized at setup() with project SR

    private var avEngine: AVAudioEngine?             // used only for input tap (recording)
    private var renderBlockWrapper: RenderBlockWrapper?
    nonisolated(unsafe) private var outputUnit: AudioUnit?
    private var midiManager: MIDI2Manager?
    // Keep plugin AU instances alive for the lifetime of AudioHost.
    // Their internalRenderBlocks are stored in RenderBlockWrapper; releasing the AU while
    // the block is registered with CoreAudio causes a null-function-pointer crash on the
    // audio IO thread (AUInternalRenderBlock retains the block object but the underlying
    // AudioUnit C struct is freed when the AUAudioUnit Swift wrapper deallocates).
    private var stereoWideAU: AUAudioUnit?
    private var reverbAU: AUAudioUnit?
    private var masterEQAU: LinearPhaseEQ?
    // Keep AUv3 insert plugins alive. Key is "channelIndex_pluginIndex" or similar.
    private var insertPlugins: [String: AUAudioUnit] = [:]
    // Keep VST3 plugins alive. Key is "channelIndex_vst3".
    private var vst3Plugins: [String: VST3Host] = [:]
    // Keep CLAP plugins alive. Key is "channelIndex_clap".
    private var clapPlugins: [String: CLAPPluginInstance] = [:]
    public let clapHost = CLAPHostManager()

    /// Project sample rate — pinned at setup time. Driven through to AudioEngine,
    /// SpatialManager, CoreAudio output unit, offline renders, and CLAP instances.
    /// Change before `setup()`; after that it's immutable for the life of this host.
    public var requestedSampleRate: Double = 44100

    public init(sampleRate: Double = 44100) {
        self.requestedSampleRate = sampleRate
        self.spatialManager = SpatialManager(sampleRate: sampleRate)
        NotificationCenter.default.addObserver(forName: NSNotification.Name("LoadExternalPlugin"), object: nil, queue: .main) { [weak self] note in
            guard let self = self, let data = note.object as? (AudioComponentDescription, Int) else { return }
            Task {
                try? await self.loadPlugin(component: data.0, for: data.1)
            }
        }
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name("LoadVST3Plugin"), object: nil, queue: .main) { [weak self] note in
            guard let self = self, let data = note.object as? (String, Int) else { return }
            Task { @MainActor in
                self.loadVST3Plugin(path: data.0, for: data.1)
            }
        }

        NotificationCenter.default.addObserver(forName: NSNotification.Name("LoadCLAPPlugin"), object: nil, queue: .main) { [weak self] note in
            guard let self = self, let data = note.object as? (CLAPPluginInfo, Int) else { return }
            Task { @MainActor in
                self.loadCLAPPlugin(info: data.0, for: data.1)
            }
        }
    }

    // MARK: Setup

    /// Cold-launch instrumentation. Wrap expensive setup phases in os_signpost
    /// intervals so Instruments.app shows where launch time goes. Target: <3 s
    /// cold start. The signpost log category is "ColdLaunch" under subsystem
    /// com.apple.ProjectToooT — filter Instruments by that.
    private static let launchLog = OSLog(
        subsystem: "com.apple.ProjectToooT", category: "ColdLaunch")

    /// Wall-clock breakdown of `AudioHost.setup()` phases. Populated on every
    /// successful setup; exposed via `lastSetupTimings`. Used by the
    /// LaunchProfile CLI to track regressions in cold-launch time.
    public struct SetupTimings: Sendable {
        public var engineBoot:     TimeInterval
        public var internalDSPBoot: TimeInterval
        public var outputUnitBoot:  TimeInterval
        public var total:           TimeInterval
        public init(engineBoot: TimeInterval = 0, internalDSPBoot: TimeInterval = 0,
                    outputUnitBoot: TimeInterval = 0, total: TimeInterval = 0) {
            self.engineBoot = engineBoot
            self.internalDSPBoot = internalDSPBoot
            self.outputUnitBoot = outputUnitBoot
            self.total = total
        }
    }
    public private(set) var lastSetupTimings: SetupTimings = SetupTimings()

    public func setup() async throws {
        let setupSignpostID = OSSignpostID(log: Self.launchLog)
        os_signpost(.begin, log: Self.launchLog, name: "AudioHost.setup", signpostID: setupSignpostID)
        defer { os_signpost(.end, log: Self.launchLog, name: "AudioHost.setup", signpostID: setupSignpostID) }
        let totalStart = CFAbsoluteTimeGetCurrent()

        // Phase 1: AUv3 subclass registration + engine instantiation.
        let auBootID = OSSignpostID(log: Self.launchLog)
        os_signpost(.begin, log: Self.launchLog, name: "EngineBoot", signpostID: auBootID)
        let engineBootStart = CFAbsoluteTimeGetCurrent()
        let cd = AudioComponentDescription(
            componentType: kAudioUnitType_Generator,
            componentSubType: 0x5054524B,
            componentManufacturer: 0x4D414444,
            componentFlags: 0, componentFlagsMask: 0)
        AUAudioUnit.registerSubclass(AudioEngine.self, as: cd, name: "PROJECT ToooT", version: 1)
        let au = try AudioEngine(componentDescription: cd, options: [], sampleRate: requestedSampleRate)
        self.trackerAU = au
        try au.allocateRenderResources()
        os_signpost(.end, log: Self.launchLog, name: "EngineBoot", signpostID: auBootID)
        lastSetupTimings.engineBoot = CFAbsoluteTimeGetCurrent() - engineBootStart

        // Phase 2: Internal DSP effects (stereo wide + reverb). Stored in
        // stereoWideAU/reverbAU so they remain alive for the full lifetime of
        // AudioHost — their internalRenderBlocks are held by RenderBlockWrapper
        // and called on the CoreAudio IO thread. Releasing the AU while the
        // block is registered causes a null-function-pointer crash (the block
        // retains the Obj-C block object, but the AudioUnit C internals are
        // freed when the AUAudioUnit Swift wrapper is released).
        let dspID = OSSignpostID(log: Self.launchLog)
        os_signpost(.begin, log: Self.launchLog, name: "InternalDSPBoot", signpostID: dspID)
        let dspBootStart = CFAbsoluteTimeGetCurrent()
        let sw = try? StereoWidePlugin(componentDescription: cd, options: [])
        try? sw?.allocateRenderResources()
        self.stereoWideAU = sw
        let rv = try? ReverbPlugin(componentDescription: cd, options: [])
        try? rv?.allocateRenderResources()
        self.reverbAU = rv
        let eq = try? LinearPhaseEQ(componentDescription: cd, options: [])
        try? eq?.allocateRenderResources()
        self.masterEQAU = eq
        os_signpost(.end, log: Self.launchLog, name: "InternalDSPBoot", signpostID: dspID)
        lastSetupTimings.internalDSPBoot = CFAbsoluteTimeGetCurrent() - dspBootStart

        // AudioRenderNode — the Swift 6 mixing core. We use the instance
        // already created by AudioEngine to ensure Timeline sync and the audio
        // thread use the same memory slabs.
        let node = au.renderNode
        self.renderNode = node

        node.midiOut = { [weak au] note, vel, ch in
            au?.midiManager?(note, vel, ch)
        }
        node.spatialPush = { [weak spatialManager] ch, buf, frames in
            spatialManager?.pushAudio(channel: ch, buffer: buf, frames: frames)
        }

        // Phase 3: CoreAudio output unit.
        let outID = OSSignpostID(log: Self.launchLog)
        os_signpost(.begin, log: Self.launchLog, name: "OutputUnitBoot", signpostID: outID)
        let outputBootStart = CFAbsoluteTimeGetCurrent()
        var outDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let outComp = AudioComponentFindNext(nil, &outDesc) else {
            hostLog.error("AudioHost.setup: no default output AudioComponent found — audio will be silent")
            os_signpost(.end, log: Self.launchLog, name: "OutputUnitBoot", signpostID: outID)
            return
        }
        var outU: AudioUnit?
        let newErr = AudioComponentInstanceNew(outComp, &outU)
        guard let outputUnit = outU, newErr == noErr else {
            hostLog.error("AudioHost.setup: AudioComponentInstanceNew failed (status \(newErr)) — audio will be silent")
            os_signpost(.end, log: Self.launchLog, name: "OutputUnitBoot", signpostID: outID)
            return
        }
        self.outputUnit = outputUnit

        let wrapper = RenderBlockWrapper(
            engineBlock:     node.renderBlock,
            stereoWideBlock: sw?.internalRenderBlock,
            reverbBlock:     rv?.internalRenderBlock,
            masterEQBlock:   eq?.internalRenderBlock,
            statePtr:        au.sharedStatePtr,
            renderResources: node.resources)
        self.renderBlockWrapper = wrapper

        var cb = AURenderCallbackStruct(
            inputProc: coreAudioRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(wrapper).toOpaque())
        AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0,
                             &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        var format = AudioStreamBasicDescription(
            mSampleRate: au.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0,
                             &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        AudioUnitInitialize(outputUnit)
        os_signpost(.end, log: Self.launchLog, name: "OutputUnitBoot", signpostID: outID)
        lastSetupTimings.outputUnitBoot = CFAbsoluteTimeGetCurrent() - outputBootStart
        lastSetupTimings.total = CFAbsoluteTimeGetCurrent() - totalStart
    }

    deinit {
        if let outputUnit = outputUnit {
            AudioOutputUnitStop(outputUnit)
            // Remove callback to prevent IO thread from accessing deallocated wrapper
            var cb = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
            AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback,
                                 kAudioUnitScope_Input, 0,
                                 &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
        }
    }

    // MARK: Transport

    public func start(bpm: Int = 125) throws {
        guard let outputUnit else { return }
        let status = AudioOutputUnitStart(outputUnit)
        if status != noErr {
            hostLog.error("AudioHost.start: AudioOutputUnitStart failed (status \(status))")
        }
        if midiManager == nil {
            let m = MIDI2Manager()
            self.midiManager = m
            if let rb = trackerAU?.eventBuffer { m.setup(ringBuffer: rb) }
            trackerAU?.midiManager = { [weak m] n, v, c in m?.sendNoteOn(note: n, velocity: v, channel: c) }
        }
        midiManager?.startClock(bpm: bpm)
    }

    public func stop() {
        midiManager?.stopClock()
        if let o = outputUnit { AudioOutputUnitStop(o) }
    }

    /// Updates the MIDI clock rate without stopping/restarting the audio engine.
    /// Call this when BPM changes mid-playback.
    public func updateClockBPM(_ bpm: Int) {
        midiManager?.startClock(bpm: bpm)
    }

    // MARK: Offline Rendering (WAV Export)

    /// Mastering options for an export pass. Pass `.none` / nil to skip each step.
    public struct ExportOptions: Sendable {
        public var loudnessTarget: MasteringExport.LoudnessTarget?
        public var ditherMode:     MasteringExport.DitherMode
        public var ditherBits:     Int   // 16 or 24; ignored for .none
        public init(loudnessTarget: MasteringExport.LoudnessTarget? = nil,
                    ditherMode:     MasteringExport.DitherMode = .none,
                    ditherBits:     Int = 24) {
            self.loudnessTarget = loudnessTarget
            self.ditherMode     = ditherMode
            self.ditherBits     = ditherBits
        }
        public static let raw = ExportOptions()   // no normalization, no dither
    }

    @discardableResult
    public func exportAudio(to url: URL, state: PlaybackState,
                            options: ExportOptions = .raw) async throws -> MasteringExport.LoudnessReport? {
        guard let node = renderNode, let engine = trackerAU else { return nil }
        let sr = engine.sampleRate

        // Calculate total samples to render at the project's sample rate.
        let ticksPerRow    = Double(state.ticksPerRow)
        let samplesPerTick = (sr * 2.5) / Double(max(32, state.bpm))
        let samplesPerRow  = samplesPerTick * ticksPerRow
        let totalRows      = Double(state.songLength * 64)
        let totalFrames    = UInt32(totalRows * samplesPerRow)

        // Publish UI instruments into the offline bank.
        for (id, inst) in state.instruments where id >= 0 && id < 256 {
            state.instrumentBank[id] = inst
        }
        let snap = SongSnapshot(
            events:      state.sequencerData.events,
            instruments: state.instrumentBank,
            orderList:   state.orderList,
            songLength:  state.songLength,
            volEnv:      state.volEnvEnabledPtr,
            panEnv:      state.panEnvEnabledPtr,
            pitchEnv:    state.pitchEnvEnabledPtr
        )

        let offlineState: UnsafeMutablePointer<EngineSharedState> = .allocate(capacity: 1)
        offlineState.initialize(to: EngineSharedState())
        offlineState.pointee.bpm          = Int32(state.bpm)
        offlineState.pointee.ticksPerRow  = Int32(state.ticksPerRow)
        offlineState.pointee.masterVolume = Float(state.masterVolume)
        offlineState.pointee.isPlaying    = 1
        defer { offlineState.deallocate() }

        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

        // Mastering options OFF → original stream-write path (zero-memory).
        // Uses the multi-core offline render — `renderOfflineConcurrent` parallelizes
        // voice processing across cores via DispatchQueue.concurrentPerform with a
        // pre-allocated per-thread scratch pool on RenderResources. Drop-in API-compatible
        // with renderOffline; same fp output, ~3-5× faster bounce on M-series.
        if options.loudnessTarget == nil && options.ditherMode == .none {
            let framesPerBuffer = 4096
            let bL: UnsafeMutablePointer<Float> = .allocate(capacity: framesPerBuffer)
            let bR: UnsafeMutablePointer<Float> = .allocate(capacity: framesPerBuffer)
            defer { bL.deallocate(); bR.deallocate() }
            let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(framesPerBuffer))!
            let file = try AVAudioFile(forWriting: url, settings: outputFormat.settings)
            var rendered: UInt32 = 0
            while rendered < totalFrames {
                let toRender = min(framesPerBuffer, Int(totalFrames - rendered))
                let actual = node.renderOfflineConcurrent(
                    frames: toRender, snap: snap, state: offlineState,
                    bufferL: bL, bufferR: bR)
                if actual == 0 { break }
                if let l = pcm.floatChannelData?[0], let r = pcm.floatChannelData?[1] {
                    memcpy(l, bL, actual * 4); memcpy(r, bR, actual * 4)
                }
                pcm.frameLength = AVAudioFrameCount(actual)
                try file.write(from: pcm)
                rendered += UInt32(actual)
                if offlineState.pointee.isPlaying == 0 { break }
            }
            return nil
        }

        // Mastering options ON → render to one big buffer, master, write.
        let N = Int(totalFrames)
        let fullL: UnsafeMutablePointer<Float> = .allocate(capacity: N)
        let fullR: UnsafeMutablePointer<Float> = .allocate(capacity: N)
        fullL.initialize(repeating: 0, count: N)
        fullR.initialize(repeating: 0, count: N)
        defer { fullL.deallocate(); fullR.deallocate() }

        var cursor = 0
        let chunk = 4096
        while cursor < N {
            let toRender = min(chunk, N - cursor)
            let actual = node.renderOfflineConcurrent(
                frames: toRender, snap: snap, state: offlineState,
                bufferL: fullL.advanced(by: cursor),
                bufferR: fullR.advanced(by: cursor))
            if actual == 0 { break }
            cursor += actual
            if offlineState.pointee.isPlaying == 0 { break }
        }
        let renderedFrames = cursor

        // Master: loudness normalize → dither → write.
        var report: MasteringExport.LoudnessReport?
        if let target = options.loudnessTarget, renderedFrames > 0 {
            report = MasteringExport.normalizeLoudness(
                bufferL: fullL, bufferR: fullR, frames: renderedFrames,
                sampleRate: sr, target: target)
        }
        if options.ditherMode != .none && renderedFrames > 0 {
            MasteringExport.applyDither(bufferL: fullL, bufferR: fullR,
                                        frames: renderedFrames,
                                        bits: options.ditherBits,
                                        mode: options.ditherMode)
        }

        // Write the mastered buffer in chunks.
        let file = try AVAudioFile(forWriting: url, settings: outputFormat.settings)
        let pcm  = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(chunk))!
        var w = 0
        while w < renderedFrames {
            let n = min(chunk, renderedFrames - w)
            if let l = pcm.floatChannelData?[0], let r = pcm.floatChannelData?[1] {
                memcpy(l, fullL.advanced(by: w), n * 4)
                memcpy(r, fullR.advanced(by: w), n * 4)
            }
            pcm.frameLength = AVAudioFrameCount(n)
            try file.write(from: pcm)
            w += n
        }
        return report
    }

    /// Renders one WAV per non-silent channel to `folder`. Each stem is the dry per-channel
    /// output scaled by its channelVolume — no master bus plugins, no limiter, so stems can be
    /// remixed externally. File naming: `stem_ch{NN}.wav`.
    ///
    /// Implementation: temporarily solos one channel at a time by zeroing out every other
    /// channel's volume around a full offline render, then restores the volumes. No engine
    /// surgery required; matches the existing renderOffline contract.
    public func exportStems(to folder: URL, state: PlaybackState) async throws {
        guard let node = renderNode, let engine = trackerAU else { return }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let sr = engine.sampleRate
        let ticksPerRow    = Double(state.ticksPerRow)
        let samplesPerTick = (sr * 2.5) / Double(max(32, state.bpm))
        let samplesPerRow  = samplesPerTick * ticksPerRow
        let totalRows      = Double(state.songLength * 64)
        let totalFrames    = UInt32(totalRows * samplesPerRow)
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

        // Publish the current PlaybackState into the offline instrument bank before rendering.
        for (id, inst) in state.instruments where id >= 0 && id < 256 {
            state.instrumentBank[id] = inst
        }
        let snap = SongSnapshot(
            events:      state.sequencerData.events,
            instruments: state.instrumentBank,
            orderList:   state.orderList,
            songLength:  state.songLength,
            volEnv:      state.volEnvEnabledPtr,
            panEnv:      state.panEnvEnabledPtr,
            pitchEnv:    state.pitchEnvEnabledPtr
        )

        // Snapshot + identify active channels (any with events in the song).
        let volsPtr = engine.channelVolumesPtr
        let originalVols = (0..<kMaxChannels).map { volsPtr[$0] }
        defer { for (i, v) in originalVols.enumerated() { volsPtr[i] = v } }

        var activeChannels: [Int] = []
        let events = state.sequencerData.events
        for ch in 0..<kMaxChannels {
            for row in 0..<state.songLength * 64 {
                let ev = events[row * kMaxChannels + ch]
                if ev.type != .empty || ev.effectCommand > 0 {
                    activeChannels.append(ch); break
                }
            }
        }

        let framesPerBuffer = 4096
        let bufferL: UnsafeMutablePointer<Float> = .allocate(capacity: framesPerBuffer)
        let bufferR: UnsafeMutablePointer<Float> = .allocate(capacity: framesPerBuffer)
        defer { bufferL.deallocate(); bufferR.deallocate() }

        for ch in activeChannels {
            // Solo: zero every channel except `ch`, using its original volume.
            for i in 0..<kMaxChannels { volsPtr[i] = (i == ch) ? originalVols[i] : 0.0 }

            let url = folder.appendingPathComponent(String(format: "stem_ch%02d.wav", ch))
            let audioFile = try AVAudioFile(forWriting: url, settings: outputFormat.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                       frameCapacity: AVAudioFrameCount(framesPerBuffer))!

            let offlineState: UnsafeMutablePointer<EngineSharedState> = .allocate(capacity: 1)
            offlineState.initialize(to: EngineSharedState())
            offlineState.pointee.bpm          = Int32(state.bpm)
            offlineState.pointee.ticksPerRow  = Int32(state.ticksPerRow)
            offlineState.pointee.masterVolume = Float(state.masterVolume)
            offlineState.pointee.isPlaying    = 1
            defer { offlineState.deallocate() }

            var framesRendered: UInt32 = 0
            while framesRendered < totalFrames {
                let toRender = min(framesPerBuffer, Int(totalFrames - framesRendered))
                let actual = node.renderOffline(frames: toRender, snap: snap, state: offlineState,
                                                bufferL: bufferL, bufferR: bufferR)
                if actual == 0 { break }

                if let l = pcm.floatChannelData?[0], let r = pcm.floatChannelData?[1] {
                    memcpy(l, bufferL, actual * MemoryLayout<Float>.size)
                    memcpy(r, bufferR, actual * MemoryLayout<Float>.size)
                }
                pcm.frameLength = AVAudioFrameCount(actual)
                try audioFile.write(from: pcm)
                framesRendered += UInt32(actual)
                if offlineState.pointee.isPlaying == 0 { break }
            }
        }
    }

    /// Renders a single channel offline (with its current plugin chain effectively bypassed at
    /// the render-block level — AUv3 inserts run in the live chain, not the offline path), then
    /// replaces the channel's events with a single note-on triggering a newly created instrument
    /// that plays the rendered audio back verbatim. Turns a plugin-heavy channel into a cheap
    /// single-voice playback during live sessions.
    ///
    /// Returns the newly created instrument ID, or `nil` on failure. Reversible via the standard
    /// undo stack (snapshotForUndo is called before the event slab is mutated).
    @discardableResult
    public func freezeChannel(_ ch: Int, state: PlaybackState) -> Int? {
        guard let node = renderNode, let engine = trackerAU,
              ch >= 0, ch < kMaxChannels else { return nil }

        let sr = engine.sampleRate
        let samplesPerTick = (sr * 2.5) / Double(max(32, state.bpm))
        let samplesPerRow  = samplesPerTick * Double(state.ticksPerRow)
        let totalFrames    = max(Int(sr / 43), Int(Double(state.songLength * 64) * samplesPerRow))

        // Solo the target channel in the offline render by zeroing the others.
        let volsPtr = engine.channelVolumesPtr
        let originalVols = (0..<kMaxChannels).map { volsPtr[$0] }
        defer { for (i, v) in originalVols.enumerated() { volsPtr[i] = v } }
        for i in 0..<kMaxChannels { volsPtr[i] = (i == ch) ? originalVols[i] : 0 }

        // Publish current PlaybackState into the offline instrument bank.
        for (id, inst) in state.instruments where id >= 0 && id < 256 {
            state.instrumentBank[id] = inst
        }
        let snap = SongSnapshot(
            events:      state.sequencerData.events,
            instruments: state.instrumentBank,
            orderList:   state.orderList,
            songLength:  state.songLength,
            volEnv:      state.volEnvEnabledPtr,
            panEnv:      state.panEnvEnabledPtr,
            pitchEnv:    state.pitchEnvEnabledPtr
        )

        let offlineState: UnsafeMutablePointer<EngineSharedState> = .allocate(capacity: 1)
        offlineState.initialize(to: EngineSharedState())
        offlineState.pointee.bpm          = Int32(state.bpm)
        offlineState.pointee.ticksPerRow  = Int32(state.ticksPerRow)
        offlineState.pointee.masterVolume = Float(state.masterVolume)
        offlineState.pointee.isPlaying    = 1
        defer { offlineState.deallocate() }

        let bufferL: UnsafeMutablePointer<Float> = .allocate(capacity: totalFrames)
        let bufferR: UnsafeMutablePointer<Float> = .allocate(capacity: totalFrames)
        defer { bufferL.deallocate(); bufferR.deallocate() }

        let renderedFrames = node.renderOffline(frames: totalFrames, snap: snap, state: offlineState,
                                                bufferL: bufferL, bufferR: bufferR)
        guard renderedFrames > 0 else { return nil }

        // Reserve space in the dynamic half of the bank and write interleaved stereo.
        let interleavedCount = renderedFrames * 2
        guard let bankOffset = engine.sampleBank.reserve(count: interleavedCount) else {
            hostLog.error("freezeChannel(\(ch)): sample bank exhausted")
            return nil
        }
        let dst = engine.sampleBank.samplePointer.advanced(by: bankOffset)
        for i in 0..<renderedFrames {
            dst[i * 2]     = bufferL[i]
            dst[i * 2 + 1] = bufferR[i]
        }

        // Allocate a fresh instrument ID (first unused slot in 1..255).
        var newInstID = -1
        for id in 1..<256 where state.instruments[id] == nil { newInstID = id; break }
        guard newInstID > 0 else { return nil }

        var frozen = Instrument()
        frozen.setName("Frozen ch\(ch + 1)")
        frozen.setSingleRegion(SampleRegion(offset: bankOffset,
                                            length: renderedFrames,
                                            isStereo: true))
        state.instruments[newInstID] = frozen
        state.instrumentBank[newInstID] = frozen

        // Rewrite the channel's events: a single note-on at row 0 triggering the frozen sample.
        state.snapshotForUndo()
        for row in 0..<state.songLength * 64 {
            state.sequencerData.events[row * kMaxChannels + ch] = .empty
        }
        state.sequencerData.events[0 * kMaxChannels + ch] = TrackerEvent(
            type: .noteOn,
            channel: UInt8(ch),
            instrument: UInt8(newInstID),
            value1: 440.0,
            value2: 1.0
        )

        // Publish the new snapshot so playback picks up the frozen sample immediately.
        node.swapSnapshot(SongSnapshot(
            events:      state.sequencerData.events,
            instruments: state.instrumentBank,
            orderList:   state.orderList,
            songLength:  state.songLength,
            volEnv:      state.volEnvEnabledPtr,
            panEnv:      state.panEnvEnabledPtr,
            pitchEnv:    state.pitchEnvEnabledPtr))

        state.textureInvalidationTrigger += 1
        state.showStatus("Froze channel \(ch + 1) → inst \(newInstID) (\(renderedFrames) frames)")
        return newInstID
    }

    // MARK: MIDI panic

    /// Hard-stops transport, kills every active voice, and sends CC 123 (All Notes Off) +
    /// CC 120 (All Sound Off) on every MIDI channel. Standard "panic button" behaviour —
    /// use when a stuck note won't release or an external synth is screaming.
    /// Sets one band of the master linear-phase EQ. `band` is 0-9 (31 Hz to
    /// 16 kHz, log-spaced); `dB` is the gain in decibels (0 = flat).
    /// The kernel is rebuilt lazily on the next render block.
    public func setMasterEQBand(_ band: Int, dB: Float) {
        masterEQAU?.setBandGain(dB, band: band)
    }

    public func midiPanic(state: PlaybackState) {
        state.isPlaying = false
        trackerAU?.sharedStatePtr.pointee.isPlaying = 0

        // Kill every voice in the render resources. `active = false` on each.
        if let node = renderNode {
            for ch in 0..<kMaxChannels {
                node.resources.voices.advanced(by: ch).pointee.active = false
            }
            node.resources.activeChannelCount = 0
        }

        // Blast All Notes Off + All Sound Off on every channel.
        // CC 120 (0x78) = All Sound Off (immediate silence — ignores release envelopes).
        // CC 123 (0x7B) = All Notes Off (triggers note-offs + lets releases play).
        if let mm = midiManager {
            for ch: UInt8 in 0..<16 {
                mm.sendControlChange(cc: 120, value: 0, channel: ch)
                mm.sendControlChange(cc: 123, value: 0, channel: ch)
            }
        }

        state.showStatus("MIDI Panic — all notes off")
    }

    // MARK: Auto-save

    /// Location: `~/Library/Application Support/ToooT/autosave/`.
    /// Rolling history of 10 files per project title. Crash recovery scans this
    /// directory on launch and offers the most recent file older than the last
    /// successful manual save.
    public static func autosaveDirectory() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("ToooT/autosave", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a timestamped autosave and prunes older files beyond the last 10.
    /// Non-blocking: schedules the write on a background Task. Safe to call from
    /// a Timer on the main actor.
    public func autosave(state: PlaybackState) {
        guard let dir = Self.autosaveDirectory() else { return }
        let safeTitle = state.songTitle.replacingOccurrences(of: "/", with: "_")
                                       .replacingOccurrences(of: ":", with: "_")
        let stamp     = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(safeTitle)_\(stamp).mad")

        let writer = MADWriter()
        let events = state.sequencerData.events
        let count  = kMaxChannels * 64 * 100
        let insts  = state.instruments
        let order  = state.orderList
        let len    = state.songLength
        let title  = state.songTitle
        let states = self.getPluginStates()
        let bank   = self.trackerAU?.sampleBank

        Task.detached(priority: .utility) {
            try? writer.write(events: events, eventCount: count,
                              instruments: insts, orderList: order,
                              songLength: len, sampleBank: bank,
                              songTitle: title, pluginStates: states, to: url)

            // Prune: keep only the 10 newest autosaves for this title.
            if let all = try? FileManager.default.contentsOfDirectory(at: dir,
                                  includingPropertiesForKeys: [.contentModificationDateKey]) {
                let mine = all
                    .filter { $0.lastPathComponent.hasPrefix(safeTitle + "_") }
                    .sorted { (a, b) in
                        let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                                         .contentModificationDate) ?? .distantPast
                        let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                                         .contentModificationDate) ?? .distantPast
                        return da > db
                    }
                for old in mine.dropFirst(10) {
                    try? FileManager.default.removeItem(at: old)
                }
            }
        }
    }

    /// Returns any autosave files newer than `maxAgeSeconds` (default 24 h). Used at
    /// app launch to detect "maybe we crashed recently" and offer recovery. Returns an
    /// empty array if the autosave dir is missing or has no recent files.
    ///
    /// The UI should walk this list and show a sheet like "X unsaved project recoveries
    /// available. [Open Latest] [Show All] [Dismiss]".
    public static func recentAutosaves(maxAgeSeconds: TimeInterval = 86_400) -> [URL] {
        guard let dir = autosaveDirectory(),
              let all = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        let cutoff = Date().addingTimeInterval(-maxAgeSeconds)
        return all.filter { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                     .contentModificationDate).map { $0 > cutoff } ?? false
        }.sorted { (a, b) in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                             .contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                             .contentModificationDate) ?? .distantPast
            return da > db
        }
    }

    /// Returns the most recent autosave file for `songTitle`, if any. Caller can
    /// offer the user a "Restore unsaved changes" prompt on launch.
    public static func latestAutosave(for songTitle: String) -> URL? {
        guard let dir = autosaveDirectory(),
              let all = try? FileManager.default.contentsOfDirectory(at: dir,
                                   includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        let safeTitle = songTitle.replacingOccurrences(of: "/", with: "_")
                                 .replacingOccurrences(of: ":", with: "_")
        return all
            .filter { $0.lastPathComponent.hasPrefix(safeTitle + "_") }
            .max { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                                 .contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                                 .contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    // MARK: AUv3 plugin hosting

    /// Registry of every AUv3 parameter exposed by hosted plugins, keyed by
    /// the automation target ID:
    ///   plugin.<channel>.<slot>.<paramAddress>     — channel inserts
    ///   plugin.<channel>.inst.<paramAddress>       — channel instrument
    ///   plugin.bus.<bus>.<slot>.<paramAddress>     — bus inserts
    ///   plugin.master.eq.<paramAddress>            — master EQ (when wired)
    ///
    /// Read by `applyPluginAutomation` from the main actor at UI tick rate
    /// (~30 Hz). Plugin parameter writes via `AUParameter.setValue` are
    /// thread-safe and don't need to live on the audio thread.
    public private(set) var pluginParamRegistry: [String: AUParameter] = [:]

    private func registerPluginParams(prefix: String, au: AUAudioUnit) {
        guard let tree = au.parameterTree else { return }
        for p in tree.allParameters {
            pluginParamRegistry["\(prefix).\(p.address)"] = p
        }
    }

    /// Direct registry write — used by tests that synthesize an AUParameter
    /// without instantiating a full plugin. Production code should prefer
    /// `loadPlugin` / `loadBusPlugin`, which auto-register via parameterTree.
    public func registerParameter(_ param: AUParameter, forTargetID id: String) {
        pluginParamRegistry[id] = param
    }

    /// Walks `lanes`, picks out every lane whose `parameter` starts with
    /// "plugin." and matches a registered AUParameter, and writes the
    /// evaluated value to that parameter. `beatNormalized` is the project
    /// playhead in [0, 1] (lane.evaluate clamps outside that range).
    /// Lane values [0, 1] are mapped onto each parameter's [min, max].
    /// Called from Timeline.syncEngineToUI at ~30 Hz.
    public func applyPluginAutomation(lanes: [Int: [BezierAutomationLane]],
                                       beatNormalized: Double) {
        guard !pluginParamRegistry.isEmpty else { return }
        for (_, lanesForCh) in lanes {
            for lane in lanesForCh where lane.parameter.hasPrefix("plugin.") {
                guard let param = pluginParamRegistry[lane.parameter] else { continue }
                let v = lane.evaluate(at: beatNormalized)
                let range = param.maxValue - param.minValue
                let target = param.minValue + Float(v) * range
                param.setValue(target, originator: nil)
            }
        }
    }

    public func loadPlugin(component: AudioComponentDescription, for channel: Int) async throws {
        let au = try await AUAudioUnit.instantiate(with: component, options: [])
        try au.allocateRenderResources()

        let isInstrument = component.componentType == kAudioUnitType_MusicDevice
        let slot: String
        let pluginID: String
        if isInstrument {
            slot = "inst"
            pluginID = "\(channel)_inst"
        } else {
            let currentCount = Int(renderBlockWrapper?.pluginCounts[channel] ?? 0)
            slot = "\(currentCount)"
            pluginID = "\(channel)_\(insertPlugins.count)"
        }
        insertPlugins[pluginID] = au
        registerPluginParams(prefix: "plugin.\(channel).\(slot)", au: au)

        if let wrapper = renderBlockWrapper, channel < kMaxChannels {
            if isInstrument {
                wrapper.instrumentBlocks[channel] = au.internalRenderBlock
            } else {
                let currentCount = Int(wrapper.pluginCounts[channel])
                if currentCount < 4 {
                    wrapper.pluginBlocks[channel * 4 + currentCount] = au.internalRenderBlock
                    wrapper.pluginCounts[channel] = Int32(currentCount + 1)
                }
            }
        }
    }

    public func loadVST3Plugin(path: String, for channel: Int) {
        // Refuse to wire the render block until the JUCE/Steinberg SDK is vendored.
        // The stub path must not replace an already-installed AUv3 instrument slot
        // with an inert passthrough.
        guard VST3Host.sdkAvailable else {
            hostLog.error("VST3 SDK not vendored — cannot load \(path). Use AUv3 plugins instead.")
            return
        }

        let vst3 = VST3Host()
        do {
            try vst3.loadPlugin(atPath: path)
        } catch {
            hostLog.error("Failed to load VST3 plugin at path \(path): \(error.localizedDescription)")
            return
        }

        guard vst3.isLoaded else {
            hostLog.error("VST3 plugin at \(path) reported !isLoaded — skipping render-block wiring")
            return
        }

        let pluginID = "\(channel)_vst3"
        vst3Plugins[pluginID] = vst3

        if let wrapper = renderBlockWrapper, channel < kMaxChannels {
            let block: AUInternalRenderBlock = { actionFlags, timestamp, frameCount, outputBusNumber, outputData, renderEvent, pullInputBlock in
                let bufList = UnsafeMutableAudioBufferListPointer(outputData)
                if bufList.count >= 2,
                   let dstL = bufList[0].mData?.assumingMemoryBound(to: Float.self),
                   let dstR = bufList[1].mData?.assumingMemoryBound(to: Float.self) {
                    vst3.processAudioBufferL(dstL, bufferR: dstR, frames: Int32(frameCount))
                }
                return noErr
            }
            wrapper.instrumentBlocks[channel] = block
        }
    }

    /// Loads a CLAP plugin onto a channel's instrument slot. Unlike VST3, CLAP is
    /// always available (BSD-licensed, no SDK gate) — if `CLAPPluginInstance` fails
    /// to instantiate we simply report and return.
    /// Loads an AUv3 effect onto an aux bus's insert chain. Up to 4 slots per bus.
    /// Bus inserts run between per-channel mixing (in AudioRenderNode) and the master
    /// sum (in RenderBlockWrapper), so they operate on the bus's unmastered audio.
    public func loadBusPlugin(component: AudioComponentDescription, busIndex: Int) async throws {
        guard busIndex >= 0, busIndex < kAuxBusCount else { return }
        let au = try await AUAudioUnit.instantiate(with: component, options: [])
        try au.allocateRenderResources()

        let pluginID = "bus\(busIndex)_\(insertPlugins.count)"
        insertPlugins[pluginID] = au

        if let wrapper = renderBlockWrapper {
            let currentCount = Int(wrapper.busPluginCounts[busIndex])
            if currentCount < 4 {
                registerPluginParams(prefix: "plugin.bus.\(busIndex).\(currentCount)", au: au)
                wrapper.busInsertBlocks[busIndex * 4 + currentCount] = au.internalRenderBlock
                wrapper.busPluginCounts[busIndex] = Int32(currentCount + 1)
            }
        }
    }

    public func loadCLAPPlugin(info: CLAPPluginInfo, for channel: Int) {
        guard channel >= 0, channel < kMaxChannels else { return }
        let sr = trackerAU?.sampleRate ?? 44100
        guard let instance = CLAPPluginInstance(info: info, sampleRate: sr, maxFrames: 4096) else {
            hostLog.error("Failed to instantiate CLAP plugin \(info.pluginID) at \(info.bundlePath)")
            return
        }

        let pluginID = "\(channel)_clap"
        clapPlugins[pluginID] = instance

        if let wrapper = renderBlockWrapper {
            let block: AUInternalRenderBlock = { _, _, frameCount, _, outputData, _, _ in
                let bufList = UnsafeMutableAudioBufferListPointer(outputData)
                if bufList.count >= 2,
                   let dstL = bufList[0].mData?.assumingMemoryBound(to: Float.self),
                   let dstR = bufList[1].mData?.assumingMemoryBound(to: Float.self) {
                    instance.process(bufferL: dstL, bufferR: dstR, frames: frameCount)
                }
                return noErr
            }
            wrapper.instrumentBlocks[channel] = block
        }
    }

    public func getPluginStates() -> [String: Data] {
        var states: [String: Data] = [:]
        for (id, au) in insertPlugins {
            if let state = au.fullStateForDocument,
               let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0) {
                states[id] = data
            }
        }
        if let sw = stereoWideAU, let state = sw.fullStateForDocument, let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0) {
            states["StereoWide"] = data
        }
        if let rv = reverbAU, let state = rv.fullStateForDocument, let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0) {
            states["ProReverb"] = data
        }
        return states
    }

    public func setPluginStates(_ states: [String: Data]) {
        for (id, au) in insertPlugins {
            if let data = states[id],
               let state = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                au.fullStateForDocument = state
            }
        }
        if let sw = stereoWideAU, let data = states["StereoWide"], let state = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            sw.fullStateForDocument = state
        }
        if let rv = reverbAU, let data = states["ProReverb"], let state = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            rv.fullStateForDocument = state
        }
    }

    // MARK: Live recording (uses AVAudioEngine input tap — separate from tracker engine)

    private let recordBufferL = AtomicRingBuffer<Float>(capacity: 262144)
    private let recordBufferR = AtomicRingBuffer<Float>(capacity: 262144)

    /// "Equation-Grade" Firewall. Zero ARC, zero objects, strictly raw pointers.
    /// This struct is passed by value into the tap closure to stop the System Trap.
    public struct AudioTapFirewall: @unchecked Sendable {
        let rbL: UnsafeMutableRawPointer
        let rbR: UnsafeMutableRawPointer
    }

    public func startRecording(state: PlaybackState) {
        if avEngine == nil { avEngine = AVAudioEngine() }
        guard let avEngine = avEngine else { return }
        
        let inputNode = avEngine.inputNode
        let format    = inputNode.outputFormat(forBus: 0)
        state.recordedSamplesL.removeAll()
        state.recordedSamplesR.removeAll()
        state.isRecording = true
        
        while recordBufferL.pop() != nil {}
        while recordBufferR.pop() != nil {}
        
        let firewall = AudioTapFirewall(
            rbL: Unmanaged.passUnretained(recordBufferL).toOpaque(),
            rbR: Unmanaged.passUnretained(recordBufferR).toOpaque()
        )

        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [firewall] buffer, _ in
            let f = Int(buffer.frameLength)
            guard f > 0, let channelData = buffer.floatChannelData else { return }
            let rbL = Unmanaged<AtomicRingBuffer<Float>>.fromOpaque(firewall.rbL).takeUnretainedValue()
            let rbR = Unmanaged<AtomicRingBuffer<Float>>.fromOpaque(firewall.rbR).takeUnretainedValue()
            let lSrc = channelData[0]
            let rSrc = buffer.format.channelCount > 1 ? channelData[1] : lSrc
            for i in 0..<f {
                _ = rbL.push(lSrc[i])
                _ = rbR.push(rSrc[i])
            }
        }
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(kMaxChannels), format: format, block: tapBlock)
        
        try? avEngine.start()
        
        Task.detached { [firewall, weak state] in
            let rbL = Unmanaged<AtomicRingBuffer<Float>>.fromOpaque(firewall.rbL).takeUnretainedValue()
            let rbR = Unmanaged<AtomicRingBuffer<Float>>.fromOpaque(firewall.rbR).takeUnretainedValue()
            
            while let s = state, await s.isRecording {
                var newL = [Float]()
                var newR = [Float]()
                while let l = rbL.pop() { newL.append(l) }
                while let r = rbR.pop() { newR.append(r) }
                
                if !newL.isEmpty {
                    await MainActor.run { [weak state] in
                        state?.recordedSamplesL.append(contentsOf: newL)
                        state?.recordedSamplesR.append(contentsOf: newR)
                    }
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    public func stopRecording(state: PlaybackState) {
        guard let avEngine = avEngine else { return }
        avEngine.inputNode.removeTap(onBus: 0)
        avEngine.stop()
        state.isRecording = false
        
        while let s = recordBufferL.pop() { state.recordedSamplesL.append(s) }
        while let s = recordBufferR.pop() { state.recordedSamplesR.append(s) }

        guard !state.recordedSamplesL.isEmpty, let engine = trackerAU else { return }

        let id  = state.selectedInstrument
        let off = (state.instruments[id]?.regionCount ?? 0) > 0 ? state.instruments[id]!.regions.0.offset : 0
        var interleaved = [Float]()
        interleaved.reserveCapacity(min(state.recordedSamplesL.count, 131072) * 2)
        for i in 0..<min(state.recordedSamplesL.count, 131072) {
            interleaved.append(state.recordedSamplesL[i])
            interleaved.append(i < state.recordedSamplesR.count ? state.recordedSamplesR[i] : 0)
        }
        engine.sampleBank.overwriteRegion(offset: off, data: interleaved)

        var inst = state.instruments[id] ?? Instrument()
        inst.setSingleRegion(SampleRegion(offset: off, length: interleaved.count, isStereo: true))
        state.instruments[id] = inst

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

        state.textureInvalidationTrigger += 1
    }
}
