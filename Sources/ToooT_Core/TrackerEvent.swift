/*
 *  PROJECT ToooT (ToooT_Core)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  Transitioning legacy tracker logic to Swift 6.
 */

import Foundation

public let kMaxChannels = 256

/// Defines a primitive, completely stateless, lock-free tracker event
/// mapped directly from legacy formats to be executed by the AudioEngine.
public enum TrackerEventType: UInt8, Sendable, BitwiseCopyable {
    case noteOn = 1
    case noteOff = 2
    case pitchBend = 3
    case setVolume = 4
    case filterCutoff = 5
    case volumeFade = 6
    case patternJump = 7
    case patternBreak = 8
    case arpeggio = 9
    case vibrato = 10
    case empty = 0 // Represents a row with no note but possibly an effect
}

/// A highly-optimized event payload dispatched via the lock-free ring buffer.
/// Explicitly aligned for C-level manipulation without Swift object overhead.
public struct TrackerEvent: Sendable, BitwiseCopyable {
    public static let empty = TrackerEvent(type: .empty, channel: 0)
    public var type: TrackerEventType
    public var channel: UInt8
    public var instrument: UInt8
    public var value1: Float32 // Could be frequency, pitch sweep, etc.
    public var value2: Float32 // Could be velocity, depth
    public var effectCommand: UInt8
    public var effectParam: UInt8
    public var probability: UInt8 // 0-100% chance to trigger
    public var algSeed: UInt8     // Seed for algorithmic generation
    
    public init(type: TrackerEventType, channel: UInt8, instrument: UInt8 = 0, value1: Float32 = 0, value2: Float32 = 0, effectCommand: UInt8 = 0, effectParam: UInt8 = 0, probability: UInt8 = 100, algSeed: UInt8 = 0) {
        self.type = type
        self.channel = channel
        self.instrument = instrument
        self.value1 = value1
        self.value2 = value2
        self.effectCommand = effectCommand
        self.effectParam = effectParam
        self.probability = probability
        self.algSeed = algSeed
    }
}
