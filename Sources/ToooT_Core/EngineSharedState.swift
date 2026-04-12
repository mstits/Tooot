/*
 *  PROJECT ToooT (ToooT_Core)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 */

import Foundation

/// Atomic state shared between the UI and the Real-Time Audio Thread.
public struct EngineSharedState {
    public var isPlaying: Int32 = 0
    public var currentEngineRow: Int32 = 0
    public var currentPattern: Int32 = 0
    public var currentOrder: Int32 = 0
    
    public var samplesProcessed: Int32 = 0
    public var samplesPerRow: Int32 = 1000
    /// Single-float atomic playhead position: integer part = pattern row [0, 63],
    /// fractional part = within-row progress [0, 1).  Written as ONE 32-bit store
    /// by the audio thread so the Metal draw thread always reads row + frac together —
    /// no torn-read race between currentEngineRow and a separate fractional field.
    public var playheadPosition: Float = 0
    /// mach_absolute_time() captured immediately before playheadPosition is written.
    /// Metal extrapolates playheadPosition forward at display refresh rate (120 Hz)
    /// between the ~5 ms audio callback writes.
    public var fractionalRowHostTime: UInt64 = 0
    /// Seconds per pattern row at the current BPM and ticksPerRow.
    /// Written alongside playheadPosition so extrapolation uses the live tempo.
    public var rowDurationSeconds: Float = 0
    
    public var peakLevel: Float = 0.0
    public var activeVoices: Int32 = 0
    public var masterVolume: Float = 0.8
    
    public var isStereoWideEnabled: Int32 = 0
    public var isReverbEnabled: Int32 = 0
    public var bpm: Int32 = 125
    public var ticksPerRow: Int32 = 6
    /// Algorithmic seed — written by the audio engine each row, read atomically by synthesis
    /// modules in NeuralIntelligenceView.  Encodes: upper 16 bits = pattern×64+row,
    /// lower 16 bits = BPM×ticksPerRow, giving a unique, tempo-aware seed per row.
    public var algSeed: UInt32 = 0
    // Note: per-channel volumes/pans are in RenderResources (AudioRenderNode) and
    // AudioEngine.channelVolumesPtr/channelPansPtr — not duplicated here.
    
    public init() {}
}
