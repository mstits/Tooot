/*
 *  PROJECT ToooT (ToooT_Core)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  SuperCollider Bridge and Algorithmic Event definitions.
 */

import Foundation

/// Defines a low-latency event mapping Tracker rows to internal SuperCollider-style synthesis.
/// The Basidium engine acts as a control-rate provider.
public struct AlgorithmicEvent: Sendable {
    public let synthDefID: UInt32
    public let channel: UInt8
    public let parameters: [Float32]
    
    public init(synthDefID: UInt32, channel: UInt8, parameters: [Float32]) {
        self.synthDefID = synthDefID
        self.channel = channel
        self.parameters = parameters
    }
}

/// A protocol for the internal synthesis server to handle AlgorithmicEvents.
public protocol SynthesisServer {
    func dispatchEvent(_ event: AlgorithmicEvent)
    func loadSynthDef(id: UInt32, definition: @escaping (DSPContext, [Float32]) -> Float)
}
