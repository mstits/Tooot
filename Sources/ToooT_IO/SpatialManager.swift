/*
 *  PROJECT ToooT (ToooT_IO)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  PHASE 3D Spatial Audio Manager.
 */

import Foundation
import PHASE
import AVFoundation

/// High-performance 3D Spatial Audio Manager using Apple PHASE.
/// Ready for Vision Pro and Immersive 2026 workflows.
public final class SpatialManager: @unchecked Sendable {
    
    private let engine: PHASEEngine
    private let listener: PHASEListener
    private var sources: [Int: PHASESource] = [:]
    private var streamNodes: [Int: PHASEPushStreamNode] = [:]
    private var soundEvents: [Int: PHASESoundEvent] = [:]
    
    // Pre-allocated mono buffers for zero-allocation push
    private var bufferPools: [Int: [AVAudioPCMBuffer]] = [:]
    private var poolIndices: [Int: Int] = [:]
    private let poolSize = 3
    
    private let audioFormat: AVAudioFormat

    public init() {
        self.engine = PHASEEngine(updateMode: .automatic)
        self.listener = PHASEListener(engine: engine)
        
        // standardFormatWithSampleRate: 44100, channels: 1 (mono for spatialization)
        self.audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
        
        // Position listener at center
        listener.transform = matrix_identity_float4x4
        try? engine.rootObject.addChild(listener)
        
        Task.detached(priority: .userInitiated) {
            try? self.engine.start()
        }
    }
    
    private func getOrCreateSource(for channel: Int) -> PHASESource {
        if let existing = sources[channel] {
            return existing
        }
        
        let source = PHASESource(engine: engine)
        try? engine.rootObject.addChild(source)
        sources[channel] = source
        
        setupPHASEStream(for: channel, source: source)
        return source
    }
    
    private func setupPHASEStream(for channel: Int, source: PHASESource) {
        // 1. Mixer Definition (Spatial head-relative for true 3D)
        let spatialPipeline = PHASESpatialPipeline(flags: [.directPathTransmission])!
        let spatialMixerDefinition = PHASESpatialMixerDefinition(spatialPipeline: spatialPipeline)
        spatialMixerDefinition.distanceModelParameters = PHASEGeometricSpreadingDistanceModelParameters()
        
        // 2. Stream Node Definition
        let streamNodeDefinition = PHASEPushStreamNodeDefinition(
            mixerDefinition: spatialMixerDefinition,
            format: audioFormat,
            identifier: "stream-\(channel)"
        )
        
        // 3. Register Asset
        let assetIdentifier = "event-\(channel)"
        do {
            try engine.assetRegistry.registerSoundEventAsset(
                rootNode: streamNodeDefinition,
                identifier: assetIdentifier
            )
        } catch {
            print("Failed to register PHASE sound event asset: \(error)")
        }
        
        // 4. Mixer Parameters
        let mixerParameters = PHASEMixerParameters()
        mixerParameters.addSpatialMixerParameters(
            identifier: spatialMixerDefinition.identifier,
            source: source,
            listener: listener
        )
        
        // 5. Start Sound Event
        if let soundEvent = try? PHASESoundEvent(
            engine: engine,
            assetIdentifier: assetIdentifier,
            mixerParameters: mixerParameters
        ) {
            soundEvents[channel] = soundEvent
            if let node = soundEvent.pushStreamNodes["stream-\(channel)"] {
                streamNodes[channel] = node
                
                // Pre-allocate buffer pool for this channel
                var pool: [AVAudioPCMBuffer] = []
                for _ in 0..<poolSize {
                    if let buf = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 4096) {
                        pool.append(buf)
                    }
                }
                bufferPools[channel] = pool
                poolIndices[channel] = 0
            }
            soundEvent.start()
        }
    }
    
    /// Pre-warms PHASE sources and stream nodes for the first `count` channels on the main thread.
    /// Must be called before playback starts so that `pushAudio(channel:buffer:frames:)` —
    /// which is called from the CoreAudio real-time thread — never creates PHASE objects
    /// on the wrong thread (PHASE API is not real-time-thread-safe).
    public func preloadChannels(count: Int) {
        for i in 0..<count {
            _ = getOrCreateSource(for: i)
        }
    }

    public func updateVoicePosition(channel: Int, x: Float, y: Float, z: Float) {
        let source = getOrCreateSource(for: channel)
        
        // Update 3D Transform
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(x, y, z, 1.0)
        source.transform = transform
    }
    
    /// Routes actual audio data from the tracker engine into PHASE.
    /// This is called from the high-priority audio thread.
    public func pushAudio(channel: Int, buffer: UnsafePointer<Float>, frames: Int) {
        guard let node = streamNodes[channel],
              let pool = bufferPools[channel],
              let idx = poolIndices[channel] else { return }
        
        let pcmBuffer = pool[idx]
        pcmBuffer.frameLength = AVAudioFrameCount(frames)
        
        // Copy mono data into the pre-allocated AVAudioPCMBuffer
        if let dest = pcmBuffer.floatChannelData?[0] {
            memcpy(dest, buffer, frames * MemoryLayout<Float>.size)
        }
        
        // Schedule in PHASE engine
        node.scheduleBuffer(buffer: pcmBuffer)
        
        // Cycle pool index
        poolIndices[channel] = (idx + 1) % poolSize
    }
    
    public func setReverbPreset(_ preset: PHASEReverbPreset) {
        // Apply the preset to the PHASE engine's default reverb setting.
        // This affects all spatial sources in the scene simultaneously.
        engine.defaultReverbPreset = preset
    }
    
    /// Tears down all PHASE resources to prevent memory leaks.
    public func stop() {
        engine.stop()
        for (_, event) in soundEvents { event.stopAndInvalidate() }
        soundEvents.removeAll()
        streamNodes.removeAll()
        sources.removeAll()
        bufferPools.removeAll()
        poolIndices.removeAll()
    }
}
