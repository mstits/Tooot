/*
 *  PROJECT ToooT (ToooT_Core)
 *  Real-time arpeggiator — MIDI / sequencer note generator.
 *
 *  Takes a set of held notes and emits them in a rate-locked order. Modes match
 *  every hardware arp ever made: up, down, updown, random, chord (all-at-once).
 *  Operates in the pure model layer — the tracker engine or MIDI input layer
 *  feeds in the held notes and pulls `next(tickIndex:)` to decide what to play.
 */

import Foundation

public struct ArpeggiatorEngine: Sendable {

    public enum Mode: String, CaseIterable, Sendable {
        case up, down, upDown, random, chord, asPlayed
    }

    public var mode: Mode = .up
    /// Notes per beat. 4 = 16ths, 2 = 8ths, 8 = 32nds, 3 = triplet 8ths.
    public var rate: Int = 4
    public var octaves: Int = 1
    public var holdMode: Bool = false
    /// 0…1. Probability of a gated-off step when mode != .random; adds humanize.
    public var gateProbability: Float = 1.0

    private var heldNotes: [Int] = []     // MIDI notes, sorted
    private var step: Int = 0
    private var direction: Int = 1        // for upDown

    public init() {}

    public mutating func noteOn(_ midiNote: Int) {
        if !heldNotes.contains(midiNote) { heldNotes.append(midiNote); heldNotes.sort() }
    }

    public mutating func noteOff(_ midiNote: Int) {
        if !holdMode { heldNotes.removeAll { $0 == midiNote } }
    }

    public mutating func clear() {
        heldNotes.removeAll()
        step = 0
        direction = 1
    }

    public var isEmpty: Bool { heldNotes.isEmpty }
    public var size: Int { heldNotes.count * octaves }

    /// Advances one arp step and returns the MIDI notes to play this step.
    /// `.chord` returns all held notes stacked; other modes return a single-element array.
    public mutating func next() -> [Int] {
        guard !heldNotes.isEmpty else { return [] }

        if mode == .chord {
            var out: [Int] = []
            for o in 0..<octaves { for n in heldNotes { out.append(n + o * 12) } }
            return out
        }

        let ordered: [Int] = {
            var base = heldNotes
            for o in 1..<octaves { base.append(contentsOf: heldNotes.map { $0 + o * 12 }) }
            switch mode {
            case .up, .upDown, .chord, .asPlayed: return base
            case .down: return base.reversed()
            case .random: return base
            }
        }()

        let count = ordered.count
        guard count > 0 else { return [] }

        let idx: Int
        switch mode {
        case .up, .down, .asPlayed:
            idx = step % count
            step += 1
        case .upDown:
            idx = step
            step += direction
            if step >= count - 1 { direction = -1 }
            if step <= 0         { direction =  1 }
        case .random:
            idx = Int.random(in: 0..<count)
        case .chord: return []   // handled above
        }

        // Gate probability: skip this step by returning empty (caller treats as rest).
        if gateProbability < 1.0 && Float.random(in: 0...1) > gateProbability {
            return []
        }
        return [ordered[max(0, min(count - 1, idx))]]
    }

    /// Samples-per-step at the given BPM and sample rate.
    public func samplesPerStep(bpm: Int, sampleRate: Double) -> Int {
        // One beat = (60 / bpm) seconds; one step = beat / rate seconds.
        let secondsPerStep = 60.0 / Double(max(1, bpm)) / Double(max(1, rate))
        return Int(secondsPerStep * sampleRate)
    }
}
