/*
 *  PROJECT ToooT (ToooT_Core)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 */

import Foundation

/// Defines a specific sample region within an instrument.
public struct SampleRegion: Sendable, BitwiseCopyable {
    public var offset: Int = 0
    public var length: Int = 0
    public var isStereo: Bool = false
    public var rootNote: Int = 60
    public var lowNote: Int = 0
    public var highNote: Int = 127
    public var loopType: LoopType = .none
    public var loopStart: Int = 0
    public var loopLength: Int = 0
    /// MOD finetune: signed value -8…+7, where each unit = 1/8 of a semitone.
    /// Applied as a frequency multiplier: pow(2, finetune / 96.0).
    /// Zero means no detuning (the common case for most samples).
    public var finetune: Int8 = 0

    public init(offset: Int, length: Int, isStereo: Bool = false) {
        self.offset = offset
        self.length = length
        self.isStereo = isStereo
    }
}

/// 1:1 Professional Instrument Structure with Keymap support.
/// Refactored for real-time safety: no Strings or Arrays.
public struct Instrument: Sendable {
    public var name: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                      Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    public var defaultVolume: Float = 1.0
    
    // Multi-Sample Keymap (Fixed 16 regions per instrument)
    public var regions: (SampleRegion, SampleRegion, SampleRegion, SampleRegion,
                         SampleRegion, SampleRegion, SampleRegion, SampleRegion,
                         SampleRegion, SampleRegion, SampleRegion, SampleRegion,
                         SampleRegion, SampleRegion, SampleRegion, SampleRegion)
    public var regionCount: Int = 0
    
    // Multi-Point Envelopes (FixedEnvelope is already real-time safe)
    public var volumeEnvelope:  FixedEnvelope = .empty
    public var panningEnvelope: FixedEnvelope = .empty
    public var pitchEnvelope:   FixedEnvelope = .empty
    
    public init() {
        let z = SampleRegion(offset: 0, length: 0)
        regions = (z,z,z,z, z,z,z,z, z,z,z,z, z,z,z,z)
    }
    
    public var nameString: String {
        get {
            return withUnsafePointer(to: name) { ptr in
                let int8Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: Int8.self)
                return String(cString: int8Ptr)
            }
        }
        set { setName(newValue) }
    }
    
    public mutating func setName(_ string: String) {
        let chars = string.prefix(31).utf8
        var i = 0
        withUnsafeMutablePointer(to: &name) { ptr in
            let int8Ptr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Int8.self)
            for char in chars {
                int8Ptr[i] = Int8(bitPattern: char)
                i += 1
            }
            while i < 32 { int8Ptr[i] = 0; i += 1 }
        }
    }

    public mutating func addRegion(_ reg: SampleRegion) {
        if regionCount < 16 {
            withUnsafeMutablePointer(to: &regions) { ptr in
                let regPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: SampleRegion.self)
                regPtr.advanced(by: regionCount).pointee = reg
            }
            regionCount += 1
        }
    }
    
    /// Replaces the first region (legacy compatibility).
    public mutating func setSingleRegion(_ reg: SampleRegion) {
        regions.0 = reg
        regionCount = 1
    }
    
    public func region(for note: Int) -> SampleRegion? {
        if regionCount == 0 { return nil }
        return withUnsafePointer(to: regions) { ptr in
            let regPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: SampleRegion.self)
            let buffer = UnsafeBufferPointer(start: regPtr, count: regionCount)
            return buffer.first { note >= $0.lowNote && note <= $0.highNote } ?? buffer.first
        }
    }
}
