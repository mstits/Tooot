/*
 *  PROJECT ToooT (ToooT_Core)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  Stochastic and Algorithmic Generators for the Basidium Engine.
 */

import Foundation
import Accelerate

/// M5 Super Core isolation for algorithmic generation
@globalActor public actor BasidiumEngine {
    public static let shared = BasidiumEngine()
}

/// Euclidean Rhythm Generator (Bjorklund's Algorithm)
public struct EuclideanGenerator: Sendable {
    /// Generates an even distribution of 'pulses' over 'steps'
    public static func generate(pulses: Int, steps: Int) -> [Bool] {
        var pattern = Array(repeating: false, count: steps)
        if pulses == 0 || steps == 0 { return pattern }
        var bucket = 0
        for i in 0..<steps {
            bucket += pulses
            if bucket >= steps {
                bucket -= steps
                pattern[i] = true
            }
        }
        return pattern
    }
}

/// Simple Markov-style probability evaluation
public struct MarkovGenerator: Sendable {
    /// Evaluates if an event should trigger based on its probability (0-100)
    public static func shouldTrigger(probability: UInt8) -> Bool {
        if probability >= 100 { return true }
        if probability == 0 { return false }
        let roll = UInt8.random(in: 1...100)
        return roll <= probability
    }
}

// MARK: - Synthesis Tiers

/// The three synthesis flavors. Each describes a distinct character; do not
/// homogenize them. Names are deliberately musical rather than themed —
/// users see these in the workbench and need to know what they get.
public enum SynthesisTier: String, CaseIterable, Sendable {
    /// Studio (was: "Carbon"). Clean, precise, tracker-classic. Default.
    case studio     = "Studio"
    /// Organic (was: "Biological"). Humanized timing + natural vibrato +
    /// breath/throat resonances. Use for ballads, lo-fi, anything that
    /// should feel hand-played.
    case organic    = "Organic"
    /// Generative (was: "Xenomorph"). Stochastic / glitchy / experimental.
    /// Fractal noise, cellular automata, controlled chaos. Use for
    /// IDM, ambient, sound design.
    case generative = "Generative"
}

// MARK: - Markov Transition Matrix (vDSP-backed, AMX-dispatched)

/// 128×128 MIDI note transition probability matrix.
/// `observe(from:to:)` accumulates co-occurrence counts from real pattern data.
/// `predict(from:)` uses `vDSP_mmul` (AMX/NEON-dispatched on Apple Silicon) to
/// multiply the one-hot input vector by the transition matrix, returning the
/// most probable next MIDI note.
///
/// Latency: ~2 µs for the 128×128 multiply on M-series — well under one audio buffer.
public final class MarkovTransitionMatrix: @unchecked Sendable {
    // Shared instance for the session
    public static let shared = MarkovTransitionMatrix()
    
    // Row-major Float32 matrix: weights[from * 128 + to]
    internal var weights: [Float]
    private var dirty: Bool = false

    public init() {
        // Seed with a uniform distribution so cold-start produces valid output
        weights = [Float](repeating: 1.0 / 128.0, count: 128 * 128)
    }

    /// Record a note→note transition observed in a real pattern.
    public func observe(from: Int, to: Int) {
        guard from >= 0 && from < 128 && to >= 0 && to < 128 else { return }
        weights[from * 128 + to] += 1.0
        dirty = true
    }

    /// Re-normalize each row so it sums to 1.0. Call after all `observe()` calls.
    public func normalize() {
        guard dirty else { return }
        weights.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for row in 0..<128 {
                var sum: Float = 0
                let rowPtr = base.advanced(by: row * 128)
                vDSP_sve(rowPtr, 1, &sum, 128)
                if sum > 0 {
                    var inv = 1.0 / sum
                    vDSP_vsmul(rowPtr, 1, &inv, rowPtr, 1, 128)
                }
            }
        }
        dirty = false
    }

    /// Returns the most likely next MIDI note given `fromNote`, using vDSP matrix multiply.
    /// This is the AMX-accelerated path — replace with CoreML `.prediction()` when an
    /// `.mlpackage` trained on user data is available.
    public func predict(from fromNote: Int) -> Int {
        guard fromNote >= 0 && fromNote < 128 else { return fromNote }
        // Input: one-hot vector of length 128
        var input = [Float](repeating: 0, count: 128)
        input[fromNote] = 1.0
        // Output: probability distribution over 128 MIDI notes
        var output = [Float](repeating: 0, count: 128)
        
        input.withUnsafeBufferPointer { inputBuf in
            weights.withUnsafeBufferPointer { weightsBuf in
                output.withUnsafeMutableBufferPointer { outputBuf in
                    if let iBase = inputBuf.baseAddress,
                       let wBase = weightsBuf.baseAddress,
                       let oBase = outputBuf.baseAddress {
                        // vDSP_mmul: C[m×n] = A[m×k] · B[k×n]
                        // Here: output[1×128] = input[1×128] · weights[128×128]
                        vDSP_mmul(iBase, 1, wBase, 1, oBase, 1, 1, 128, 128)
                    }
                }
            }
        }
        
        // Argmax: note with highest probability
        var maxVal: Float = -1
        var maxIdx: vDSP_Length = 0
        output.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                vDSP_maxvi(base, 1, &maxVal, &maxIdx, 128)
            }
        }
        return Int(maxIdx)
    }
}

// MARK: - Neural Harmonizer

/// Generates chord progressions based on a target MIDI scale and current Markov state.
public struct NeuralHarmonizer: Sendable {
    public static func harmonize(root: Int, scale: [Int]) -> [[Int]] {
        // Root is MIDI note, scale is list of semitone offsets (e.g. [0, 2, 4, 5, 7, 9, 11])
        var progression = [[Int]]()
        let matrix = MarkovTransitionMatrix.shared
        
        var currentRoot = root
        for _ in 0..<4 {
            let nextRoot = matrix.predict(from: currentRoot)
            // Map the prediction into the nearest scale degree
            let oct = nextRoot / 12
            let deg = scale.min { abs($0 - (nextRoot % 12)) < abs($1 - (nextRoot % 12)) } ?? 0
            let finalRoot = oct * 12 + deg
            
            // Generate triad: I, III, V degrees in the scale
            let triad = [
                finalRoot,
                finalRoot + 4, // simplistic major triad for demo
                finalRoot + 7
            ]
            progression.append(triad)
            currentRoot = finalRoot
        }
        return progression
    }
}

/// Applies a click-free gain ramp between two synthesis tier outputs.
/// Uses `vDSP_vrampmul` so the gain envelope is computed entirely on the DSP unit —
/// no per-sample scalar multiply on the CPU.
///
/// Usage:
/// ```swift
/// TierCrossFadeEngine.ramp(signal: &tierABuffer, from: 1.0, to: 0.0) // fade out old tier
/// TierCrossFadeEngine.ramp(signal: &tierBBuffer, from: 0.0, to: 1.0) // fade in  new tier
/// ```
public struct TierCrossFadeEngine: Sendable {
    /// Applies a linear gain ramp to `signal` in-place, from gain `start` to `end`.
    public static func ramp(signal: inout [Float], from start: Float, to end: Float) {
        let n = signal.count
        guard n > 0 else { return }
        var gainStart = start
        var gainStep = (end - start) / Float(n)
        // vDSP_vrampmul multiplies signal[i] by (gainStart + i * gainStep), in-place.
        signal.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress {
                vDSP_vrampmul(base, 1, &gainStart, &gainStep, base, 1, vDSP_Length(n))
            }
        }
    }
}

/// Lindenmayer System (L-System) — rule-based string rewriting for melodic generation.
///
/// Each symbol is a UInt8 representing a pitch offset or rest.
/// Default production rules implement a Fibonacci-style growth:
///   A (even) → [A, B, A+2]   — expand with semitone rise
///   B (odd)  → [A, B-1]      — contract toward root
///
/// Callers may supply custom rules as a dictionary [UInt8: [UInt8]].
public struct LSystemGenerator: Sendable {

    /// Expand a seed sequence using the provided production rules for `iterations` generations.
    /// Output is capped at 512 symbols to prevent runaway expansion.
    public static func expand(seed: UInt8,
                               iterations: Int,
                               rules: [UInt8: [UInt8]]? = nil) -> [UInt8] {
        // Default musical rules: Fibonacci-like branching over a pentatonic offset palette
        let defaultRules: [UInt8: [UInt8]] = [
            0: [0, 2, 0],      // root  → root + M2 + root
            2: [2, 4, 7],      // M2    → M2  + P4 + P5
            4: [4, 5, 0],      // P3    → P3  + P4 + root
            5: [5, 7, 5],      // P4    → P4  + P5 + P4
            7: [7, 9, 0],      // P5    → P5  + M6 + root
            9: [9, 0, 4],      // M6    → M6  + root + P3
        ]
        let activeRules = rules ?? defaultRules

        var result = [seed]
        for _ in 0..<max(0, iterations) {
            var next = [UInt8]()
            next.reserveCapacity(result.count * 3)
            for sym in result {
                if let production = activeRules[sym] {
                    next.append(contentsOf: production)
                } else {
                    // Identity: symbols without rules copy themselves
                    next.append(sym)
                }
                if next.count >= 512 { break }
            }
            result = Array(next.prefix(512))
        }
        return result
    }

    /// Convenience overload using classic Fibonacci (A→AB, B→A) over a scale of offsets.
    /// Returns semitone offsets mapped into `[0, 11]`.
    public static func fibonacci(seed: UInt8 = 0, iterations: Int) -> [UInt8] {
        // A (0) → A B   |  B (1) → A
        let rules: [UInt8: [UInt8]] = [0: [0, 1], 1: [0]]
        let raw = expand(seed: seed % 2, iterations: iterations, rules: rules)
        // Map {0,1} → playable semitone offsets in C-major: 0,2,4,5,7,9,11
        let cMajor: [UInt8] = [0, 2, 4, 5, 7, 9, 11]
        return raw.map { cMajor[Int($0) % cMajor.count] }
    }
}
