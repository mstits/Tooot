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
import os.log
import ToooT_Core
import ToooT_Plugins
import ToooT_IO

private let hostLog = Logger(subsystem: "com.apple.ProjectToooT", category: "AudioHost")

// MARK: - Render callback wrapper (lives on the CoreAudio real-time thread)

private final class RenderBlockWrapper: @unchecked Sendable {
    // engineBlock is now AudioRenderNode.renderBlock — race-free.
    let engineBlock:    AUInternalRenderBlock
    let stereoWideBlock: AUInternalRenderBlock?
    let reverbBlock:    AUInternalRenderBlock?
    let statePtr:       UnsafeMutablePointer<EngineSharedState>

    // Per-channel AUv3 insert chains. 
    // We use a fixed-size array of pointers to blocks to ensure RT-safety.
    // kMaxChannels channels, max 4 plugins per channel.
    nonisolated(unsafe) let pluginBlocks: UnsafeMutablePointer<AUInternalRenderBlock?>
    nonisolated(unsafe) let pluginCounts: UnsafeMutablePointer<Int32>

    init(engineBlock:    @escaping AUInternalRenderBlock,
         stereoWideBlock: AUInternalRenderBlock?,
         reverbBlock:    AUInternalRenderBlock?,
         statePtr:       UnsafeMutablePointer<EngineSharedState>) {
        self.engineBlock     = engineBlock
        self.stereoWideBlock = stereoWideBlock
        self.reverbBlock     = reverbBlock
        self.statePtr        = statePtr
        
        self.pluginBlocks = .allocate(capacity: kMaxChannels * 4)
        self.pluginBlocks.initialize(repeating: nil, count: kMaxChannels * 4)
        self.pluginCounts = .allocate(capacity: kMaxChannels)
        self.pluginCounts.initialize(repeating: 0, count: kMaxChannels)
    }
    
    deinit {
        pluginBlocks.deallocate()
        pluginCounts.deallocate()
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

    // 2. Per-channel AUv3 insert chains (RT-safe loop)
    for ch in 0..<kMaxChannels {
        let count = wrapper.pluginCounts[ch]
        for p in 0..<Int(count) {
            if let block = wrapper.pluginBlocks[ch * 4 + p] {
                _ = block(ioActionFlags, inTimeStamp, inNumberFrames, 0, ioData, nil, nil)
            }
        }
    }

    // 3. Internal vDSP effects (stereo widening, reverb)
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
    public let spatialManager = SpatialManager()     // Apple PHASE 3D Engine

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
    // Keep AUv3 insert plugins alive. Key is "channelIndex_pluginIndex" or similar.
    private var insertPlugins: [String: AUAudioUnit] = [:]

    public init() {}

    // MARK: Setup

    public func setup() async throws {
        // Register AUAudioUnit subclass (required for AUv3 hosting ecosystem)
        let cd = AudioComponentDescription(
            componentType: kAudioUnitType_Generator,
            componentSubType: 0x5054524B,
            componentManufacturer: 0x4D414444,
            componentFlags: 0, componentFlagsMask: 0)
        AUAudioUnit.registerSubclass(AudioEngine.self, as: cd, name: "PROJECT ToooT", version: 1)
        let au = try AudioEngine(componentDescription: cd, options: [])
        self.trackerAU = au
        try au.allocateRenderResources()

        // Internal DSP effects. Stored in stereoWideAU/reverbAU so they remain alive for the
        // full lifetime of AudioHost — their internalRenderBlocks are held by RenderBlockWrapper
        // and called on the CoreAudio IO thread. Releasing the AU while the block is registered
        // causes a null-function-pointer crash (the block retains the Obj-C block object, but
        // the AudioUnit C internals are freed when the AUAudioUnit Swift wrapper is released).
        let sw = try? StereoWidePlugin(componentDescription: cd, options: [])
        try? sw?.allocateRenderResources()
        self.stereoWideAU = sw
        let rv = try? ReverbPlugin(componentDescription: cd, options: [])
        try? rv?.allocateRenderResources()
        self.reverbAU = rv

        // AudioRenderNode — the Swift 6 mixing core.
        // We use the instance already created by AudioEngine to ensure 
        // Timeline sync and the audio thread use the same memory slabs.
        let node = au.renderNode
        self.renderNode = node

        // Wire MIDI output from the render node back through the engine's callback slot
        node.midiOut = { [weak au] note, vel, ch in
            au?.midiManager?(note, vel, ch)
        }

        // Wire Spatial Audio (PHASE).
        node.spatialPush = { [weak spatialManager] ch, buf, frames in
            spatialManager?.pushAudio(channel: ch, buffer: buf, frames: frames)
        }

        // CoreAudio output unit
        var outDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let outComp = AudioComponentFindNext(nil, &outDesc) else {
            hostLog.error("AudioHost.setup: no default output AudioComponent found — audio will be silent")
            return
        }
        var outU: AudioUnit?
        let newErr = AudioComponentInstanceNew(outComp, &outU)
        guard let outputUnit = outU, newErr == noErr else {
            hostLog.error("AudioHost.setup: AudioComponentInstanceNew failed (status \(newErr)) — audio will be silent")
            return
        }
        self.outputUnit = outputUnit

        // Use node.renderBlock — race-free, Float-only, zero Double roundtrip.
        let wrapper = RenderBlockWrapper(
            engineBlock:     node.renderBlock,
            stereoWideBlock: sw?.internalRenderBlock,
            reverbBlock:     rv?.internalRenderBlock,
            statePtr:        au.sharedStatePtr)
        self.renderBlockWrapper = wrapper

        var cb = AURenderCallbackStruct(
            inputProc: coreAudioRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(wrapper).toOpaque())
        AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0,
                             &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        var format = AudioStreamBasicDescription(
            mSampleRate: 44100.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0,
                             &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        AudioUnitInitialize(outputUnit)
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

    public func exportAudio(to url: URL, state: PlaybackState) async throws {
        guard let node = renderNode, trackerAU != nil else { return }
        
        // Calculate total samples to render
        let ticksPerRow = Double(state.ticksPerRow)
        let samplesPerTick = (44100.0 * 2.5) / Double(max(32, state.bpm))
        let samplesPerRow = samplesPerTick * ticksPerRow
        let totalRows = Double(state.songLength * 64)
        let totalFrames = UInt32(totalRows * samplesPerRow)
        
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let audioFile = try AVAudioFile(forWriting: url, settings: outputFormat.settings)
        
        // Create an offline snapshot
        for (id, inst) in state.instruments {
            if id >= 0 && id < 256 {
                state.instrumentBank[id] = inst
            }
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
        offlineState.pointee.bpm = Int32(state.bpm)
        offlineState.pointee.ticksPerRow = Int32(state.ticksPerRow)
        offlineState.pointee.masterVolume = Float(state.masterVolume)
        offlineState.pointee.isPlaying = 1
        
        let framesPerBuffer: Int = 4096
        let bufferL: UnsafeMutablePointer<Float> = .allocate(capacity: framesPerBuffer)
        let bufferR: UnsafeMutablePointer<Float> = .allocate(capacity: framesPerBuffer)
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(framesPerBuffer))!
        
        defer {
            offlineState.deallocate()
            bufferL.deallocate()
            bufferR.deallocate()
        }
        
        var framesRendered: UInt32 = 0
        while framesRendered < totalFrames {
            let toRender = min(Int(framesPerBuffer), Int(totalFrames - framesRendered))
            let actualRendered = node.renderOffline(frames: toRender, snap: snap, state: offlineState, bufferL: bufferL, bufferR: bufferR)
            
            if actualRendered == 0 { break }
            
            // Copy non-interleaved pointers to AVAudioPCMBuffer
            if let leftChannel = pcmBuffer.floatChannelData?[0], let rightChannel = pcmBuffer.floatChannelData?[1] {
                memcpy(leftChannel, bufferL, actualRendered * 4)
                memcpy(rightChannel, bufferR, actualRendered * 4)
            }
            pcmBuffer.frameLength = AVAudioFrameCount(actualRendered)
            
            try audioFile.write(from: pcmBuffer)
            framesRendered += UInt32(actualRendered)
            
            if offlineState.pointee.isPlaying == 0 { break }
        }
    }

    // MARK: AUv3 plugin hosting

    public func loadPlugin(component: AudioComponentDescription, for channel: Int) async throws {
        let au = try AUAudioUnit(componentDescription: component, options: [])
        try au.allocateRenderResources()
        let pluginID = "\(channel)_\(insertPlugins.count)"
        insertPlugins[pluginID] = au
        
        if let wrapper = renderBlockWrapper, channel < kMaxChannels {
            let currentCount = Int(wrapper.pluginCounts[channel])
            if currentCount < 4 {
                wrapper.pluginBlocks[channel * 4 + currentCount] = au.internalRenderBlock
                wrapper.pluginCounts[channel] = Int32(currentCount + 1)
            }
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
