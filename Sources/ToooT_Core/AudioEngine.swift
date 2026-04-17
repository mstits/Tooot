/*
 *  PROJECT ToooT (ToooT_Core)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  64-bit Summing Engine for macOS 16.
 */

import Foundation
import AVFoundation
import CoreMIDI
import Accelerate

/// The Real-time Audio Actor for PROJECT ToooT.
@globalActor public actor RenderActor {
    public static let shared = RenderActor()
}

/// Native 2026 Audio Engine utilizing the AudioRenderNode and Swift 6 concurrency.
public final class AudioEngine: AUAudioUnit, @unchecked Sendable {
    public let eventBuffer: AtomicRingBuffer<TrackerEvent>
    public let sampleBank: UnifiedSampleBank
    public let sharedStatePtr: UnsafeMutablePointer<EngineSharedState>

    /// Project sample rate. Fixed at engine init; 44.1 k for tracker legacy, 48 k for broadcast,
    /// 96 k for mastering, up to 192 k for archival. Changing mid-session requires restarting
    /// the engine (CoreAudio output unit's stream format is fixed at `AudioUnitInitialize`).
    public let sampleRate: Double

    // The new zero-allocation render node
    public let renderNode: AudioRenderNode
    private let renderResources: RenderResources

    public var channelVolumesPtr: UnsafeMutablePointer<Float> { renderResources.channelVolumes }
    public var channelPansPtr: UnsafeMutablePointer<Float> { renderResources.channelPans }
    public var midiEnabledChannelsPtr: UnsafeMutablePointer<Int32> { renderResources.channelMidiFlags }

    public var midiManager: (@Sendable (UInt8, UInt8, UInt8) -> Void)? {
        didSet { renderNode.midiOut = midiManager }
    }
    
    private var _outputBusses: AUAudioUnitBusArray!
    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    public override convenience init(componentDescription: AudioComponentDescription,
                                     options: AudioComponentInstantiationOptions = []) throws {
        try self.init(componentDescription: componentDescription, options: options, sampleRate: 44100)
    }

    public init(componentDescription: AudioComponentDescription,
                options: AudioComponentInstantiationOptions = [],
                sampleRate: Double) throws {
        self.sampleRate  = sampleRate
        self.eventBuffer = AtomicRingBuffer<TrackerEvent>(capacity: 1024)
        self.sampleBank  = UnifiedSampleBank(capacity: 1024 * 1024 * 64) // 256MB

        self.sharedStatePtr = .allocate(capacity: 1)
        self.sharedStatePtr.initialize(to: EngineSharedState())

        self.renderResources = RenderResources(maxFrames: 4096)
        self.renderNode = AudioRenderNode(resources: self.renderResources,
                                          statePtr: self.sharedStatePtr,
                                          bank: self.sampleBank,
                                          eventBuffer: self.eventBuffer,
                                          sampleRate: sampleRate)

        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let bus = try AUAudioUnitBus(format: format)
        self._outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [bus])
    }
    
    deinit {
        sharedStatePtr.deallocate()
    }

    /// Swap the atomic snapshot from the main thread when sequencer data changes.
    public func updateSongSnapshot(_ newSnapshot: SongSnapshot) {
        renderNode.swapSnapshot(newSnapshot)
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        return renderNode.renderBlock
    }
}
