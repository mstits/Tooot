/*
 *  PROJECT ToooT (ToooT_Core)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 */

import Foundation
import Accelerate

public extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// A thread-safe contextual structure that pre-allocates memory for DSP operations.
/// Uses raw pointers to satisfy strict Sendable requirements for the audio thread.
public final class DSPContext: @unchecked Sendable {
    
    /// Polyphonic Voice Slab (256 channels)
    public let voices: UnsafeMutablePointer<SynthVoice>
    public let voiceCount: Int = 256
    
    /// Scratch buffers for SIMD operations
    public let scratchBufferL: UnsafeMutablePointer<Float>
    public let scratchBufferR: UnsafeMutablePointer<Float>
    
    /// 64-bit scratch for high-precision summing promotion
    public let summationScratch: UnsafeMutablePointer<Double>
    
    /// Vectorized interpolation indices
    public let fractionalIndices: UnsafeMutablePointer<Float>
    public let voiceInterpolationBuffer: UnsafeMutablePointer<Float>
    
    public let volumeEnvelope: UnsafeMutablePointer<Float>
    
    public init(maximumFrames: Int = 4096) {
        // Allocate and initialize voices
        self.voices = .allocate(capacity: 256)
        self.voices.initialize(repeating: SynthVoice(), count: 256)
        
        self.scratchBufferL = .allocate(capacity: maximumFrames)
        self.scratchBufferR = .allocate(capacity: maximumFrames)
        self.summationScratch = .allocate(capacity: maximumFrames)
        self.fractionalIndices = .allocate(capacity: maximumFrames)
        self.voiceInterpolationBuffer = .allocate(capacity: maximumFrames)
        self.volumeEnvelope = .allocate(capacity: maximumFrames)
        
        self.scratchBufferL.initialize(repeating: 0.0, count: maximumFrames)
        self.scratchBufferR.initialize(repeating: 0.0, count: maximumFrames)
        self.summationScratch.initialize(repeating: 0.0, count: maximumFrames)
        self.fractionalIndices.initialize(repeating: 0.0, count: maximumFrames)
        self.voiceInterpolationBuffer.initialize(repeating: 0.0, count: maximumFrames)
        self.volumeEnvelope.initialize(repeating: 1.0, count: maximumFrames)
    }

    deinit {
        voices.deallocate()
        scratchBufferL.deallocate()
        scratchBufferR.deallocate()
        summationScratch.deallocate()
        fractionalIndices.deallocate()
        voiceInterpolationBuffer.deallocate()
        volumeEnvelope.deallocate()
    }
}
