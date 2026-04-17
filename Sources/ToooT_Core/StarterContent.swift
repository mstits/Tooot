/*
 *  PROJECT ToooT (ToooT_Core)
 *  Starter content generator — synthesizes a usable kit + lead + bass + pad
 *  + percussion bank programmatically at runtime.
 *
 *  Why in-code instead of shipped WAV files: keeps the repo small, stays in
 *  sync with sample-rate changes, and gives us a deterministic "starter
 *  project" that users can immediately listen to. Offline rendering the kit
 *  once on first launch produces ~1 MB of PCM in the UnifiedSampleBank.
 *
 *  The bank is laid out in deterministic slots so the Starter Kit template
 *  (see Templates.swift) can reference instrument IDs 1–32 with known offsets.
 */

import Foundation
import Accelerate

public enum StarterContent {

    /// Each entry describes one instrument: how to synthesize it, how many
    /// PCM samples to allocate, and what MIDI note range it covers.
    public struct Item: Sendable {
        public let id:        Int
        public let name:      String
        public let category:  Category
        public let frames:    Int
        public let sampleRate: Float
        public let synthesize: @Sendable (UnsafeMutablePointer<Float>, Int, Float) -> Void

        public enum Category: String, Sendable { case drum, bass, lead, pad, percussion, fx }
    }

    // MARK: - The catalogue (32 items)

    public static let catalogue: [Item] = [
        // ─── Drum kit (IDs 1–8) ─────────────────────────────────────────────
        Item(id: 1, name: "Kick",       category: .drum, frames: 8_000, sampleRate: 44100) { p, n, _ in
            synthKick(into: p, frames: n, sampleRate: 44100)
        },
        Item(id: 2, name: "Snare",      category: .drum, frames: 8_000, sampleRate: 44100) { p, n, _ in
            synthSnare(into: p, frames: n, sampleRate: 44100)
        },
        Item(id: 3, name: "Hi-Hat",     category: .drum, frames: 4_000, sampleRate: 44100) { p, n, _ in
            synthHat(into: p, frames: n, closed: true)
        },
        Item(id: 4, name: "Open Hat",   category: .drum, frames: 12_000, sampleRate: 44100) { p, n, _ in
            synthHat(into: p, frames: n, closed: false)
        },
        Item(id: 5, name: "Clap",       category: .drum, frames: 6_000, sampleRate: 44100) { p, n, _ in
            synthClap(into: p, frames: n)
        },
        Item(id: 6, name: "Tom Low",    category: .drum, frames: 10_000, sampleRate: 44100) { p, n, _ in
            synthTom(into: p, frames: n, freq: 80)
        },
        Item(id: 7, name: "Tom Mid",    category: .drum, frames: 9_000, sampleRate: 44100) { p, n, _ in
            synthTom(into: p, frames: n, freq: 140)
        },
        Item(id: 8, name: "Crash",      category: .drum, frames: 20_000, sampleRate: 44100) { p, n, _ in
            synthCrash(into: p, frames: n)
        },
        // ─── Bass (IDs 9–12) ────────────────────────────────────────────────
        Item(id: 9,  name: "Sub Bass",   category: .bass, frames: 22_050, sampleRate: 44100) { p, n, _ in
            synthBass(into: p, frames: n, freq: 55, shape: .sine)
        },
        Item(id: 10, name: "Square Bass",category: .bass, frames: 22_050, sampleRate: 44100) { p, n, _ in
            synthBass(into: p, frames: n, freq: 55, shape: .square)
        },
        Item(id: 11, name: "Saw Bass",   category: .bass, frames: 22_050, sampleRate: 44100) { p, n, _ in
            synthBass(into: p, frames: n, freq: 55, shape: .saw)
        },
        Item(id: 12, name: "Rez Bass",   category: .bass, frames: 22_050, sampleRate: 44100) { p, n, _ in
            synthRezBass(into: p, frames: n, freq: 55)
        },
        // ─── Lead (IDs 13–16) ───────────────────────────────────────────────
        Item(id: 13, name: "Saw Lead",   category: .lead, frames: 22_050, sampleRate: 44100) { p, n, _ in
            synthLead(into: p, frames: n, freq: 440, shape: .saw)
        },
        Item(id: 14, name: "Square Lead",category: .lead, frames: 22_050, sampleRate: 44100) { p, n, _ in
            synthLead(into: p, frames: n, freq: 440, shape: .square)
        },
        Item(id: 15, name: "PWM Lead",   category: .lead, frames: 22_050, sampleRate: 44100) { p, n, _ in
            synthPWMLead(into: p, frames: n, freq: 440)
        },
        Item(id: 16, name: "FM Lead",    category: .lead, frames: 22_050, sampleRate: 44100) { p, n, _ in
            synthFMLead(into: p, frames: n, freq: 440, ratio: 2, mod: 3)
        },
        // ─── Pad (IDs 17–20) ────────────────────────────────────────────────
        Item(id: 17, name: "Warm Pad",   category: .pad, frames: 44_100, sampleRate: 44100) { p, n, _ in
            synthPad(into: p, frames: n, freq: 220, layers: 3)
        },
        Item(id: 18, name: "Choir Pad",  category: .pad, frames: 44_100, sampleRate: 44100) { p, n, _ in
            synthPad(into: p, frames: n, freq: 330, layers: 5)
        },
        Item(id: 19, name: "Bell Pad",   category: .pad, frames: 44_100, sampleRate: 44100) { p, n, _ in
            synthBell(into: p, frames: n, freq: 440)
        },
        Item(id: 20, name: "Stab Pad",   category: .pad, frames: 22_050, sampleRate: 44100) { p, n, _ in
            synthPad(into: p, frames: n, freq: 220, layers: 2)
        },
        // ─── Percussion (IDs 21–26) ─────────────────────────────────────────
        Item(id: 21, name: "Cowbell",    category: .percussion, frames: 8_000, sampleRate: 44100) { p, n, _ in
            synthCowbell(into: p, frames: n)
        },
        Item(id: 22, name: "Rim Shot",   category: .percussion, frames: 4_000, sampleRate: 44100) { p, n, _ in
            synthRim(into: p, frames: n)
        },
        Item(id: 23, name: "Shaker",     category: .percussion, frames: 4_000, sampleRate: 44100) { p, n, _ in
            synthShaker(into: p, frames: n)
        },
        Item(id: 24, name: "Wood Block", category: .percussion, frames: 5_000, sampleRate: 44100) { p, n, _ in
            synthWoodBlock(into: p, frames: n)
        },
        Item(id: 25, name: "Conga",      category: .percussion, frames: 7_000, sampleRate: 44100) { p, n, _ in
            synthTom(into: p, frames: n, freq: 200)
        },
        Item(id: 26, name: "Click",      category: .percussion, frames: 2_000, sampleRate: 44100) { p, n, _ in
            synthClick(into: p, frames: n)
        },
        // ─── FX (IDs 27–32) ─────────────────────────────────────────────────
        Item(id: 27, name: "White Noise",category: .fx, frames: 44_100, sampleRate: 44100) { p, n, _ in
            for i in 0..<n { p[i] = Float.random(in: -0.5...0.5) }
        },
        Item(id: 28, name: "Sweep Up",   category: .fx, frames: 22_050, sampleRate: 44100) { p, n, _ in
            synthSweep(into: p, frames: n, startFreq: 200, endFreq: 4000)
        },
        Item(id: 29, name: "Sweep Down", category: .fx, frames: 22_050, sampleRate: 44100) { p, n, _ in
            synthSweep(into: p, frames: n, startFreq: 4000, endFreq: 200)
        },
        Item(id: 30, name: "Zap",        category: .fx, frames: 8_000, sampleRate: 44100) { p, n, _ in
            synthZap(into: p, frames: n)
        },
        Item(id: 31, name: "Pulse Wave", category: .fx, frames: 22_050, sampleRate: 44100) { p, n, _ in
            synthPulse(into: p, frames: n, freq: 110)
        },
        Item(id: 32, name: "Metal Hit",  category: .fx, frames: 10_000, sampleRate: 44100) { p, n, _ in
            synthMetal(into: p, frames: n)
        },
    ]

    /// Total frames needed for the full kit.
    public static var totalFrames: Int {
        catalogue.reduce(0) { $0 + $1.frames }
    }

    /// Populates `bank` with the full starter kit. Returns a map of
    /// `instrumentID → (offset, length)` for the tracker to reference.
    /// Call once on first-launch or when restoring the Starter Kit template.
    public static func install(into bank: UnifiedSampleBank) -> [Int: (offset: Int, length: Int)] {
        var offsets: [Int: (offset: Int, length: Int)] = [:]
        var cursor = 0
        for item in catalogue {
            let base: UnsafeMutablePointer<Float>
            if cursor + item.frames <= bank.totalSamples {
                base = bank.samplePointer.advanced(by: cursor)
                item.synthesize(base, item.frames, item.sampleRate)
                offsets[item.id] = (cursor, item.frames)
                cursor += item.frames
            }
        }
        return offsets
    }
}

// MARK: - Synthesis primitives

fileprivate enum Shape { case sine, square, saw, triangle }

fileprivate func envelope(_ frame: Int, of total: Int, attack: Float = 0.01, decay: Float = 0.3) -> Float {
    let t = Float(frame) / Float(total)
    if t < attack { return t / attack }
    let dec = 1.0 - min(1.0, (t - attack) / decay)
    return max(0, dec)
}

fileprivate func synthKick(into p: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Float) {
    for i in 0..<frames {
        let t = Float(i) / sampleRate
        let pitch = 60 * expf(-t * 35)   // pitch drop from 60 Hz down
        let body  = sinf(2 * .pi * pitch * t) * expf(-t * 8)
        let click = (Float.random(in: -1...1)) * expf(-t * 300) * 0.15
        p[i] = (body + click) * 0.8
    }
}

fileprivate func synthSnare(into p: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Float) {
    for i in 0..<frames {
        let t = Float(i) / sampleRate
        let tone  = sinf(2 * .pi * 200 * t) * expf(-t * 20) * 0.4
        let noise = Float.random(in: -1...1) * expf(-t * 15) * 0.6
        p[i] = (tone + noise) * 0.7
    }
}

fileprivate func synthHat(into p: UnsafeMutablePointer<Float>, frames: Int, closed: Bool) {
    let decay: Float = closed ? 80 : 20
    for i in 0..<frames {
        let t = Float(i) / 44100
        p[i] = Float.random(in: -1...1) * expf(-t * decay) * 0.5
    }
}

fileprivate func synthClap(into p: UnsafeMutablePointer<Float>, frames: Int) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        // Three fast-decaying noise bursts.
        var v: Float = 0
        for offset: Float in [0, 0.01, 0.02] {
            let lt = max(0, t - offset)
            v += Float.random(in: -1...1) * expf(-lt * 60) * 0.3
        }
        p[i] = v
    }
}

fileprivate func synthTom(into p: UnsafeMutablePointer<Float>, frames: Int, freq: Float) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        let pitch = freq * expf(-t * 3)
        p[i] = sinf(2 * .pi * pitch * t) * expf(-t * 6) * 0.7
    }
}

fileprivate func synthCrash(into p: UnsafeMutablePointer<Float>, frames: Int) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        p[i] = Float.random(in: -1...1) * expf(-t * 3) * 0.6
    }
}

fileprivate func synthBass(into p: UnsafeMutablePointer<Float>, frames: Int, freq: Float, shape: Shape) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        let phase = 2 * .pi * freq * t
        let raw: Float
        switch shape {
        case .sine:     raw = sinf(phase)
        case .square:   raw = sinf(phase) >= 0 ? 0.8 : -0.8
        case .saw:      raw = 2 * (freq * t - floorf(freq * t + 0.5))
        case .triangle: raw = 2 * abs(2 * (freq * t - floorf(freq * t + 0.5))) - 1
        }
        let env = envelope(i, of: frames, attack: 0.005, decay: 0.5)
        p[i] = raw * env * 0.7
    }
}

fileprivate func synthRezBass(into p: UnsafeMutablePointer<Float>, frames: Int, freq: Float) {
    var state: Float = 0, state2: Float = 0
    let cutoff: Float = 1500
    let q: Float      = 3.0
    let coef = 2 * .pi * cutoff / 44100
    for i in 0..<frames {
        let t = Float(i) / 44100
        let saw = 2 * (freq * t - floorf(freq * t + 0.5))
        let env = envelope(i, of: frames, attack: 0.002, decay: 0.35)
        // Cheap resonant 2-pole filter.
        let hp = saw - state
        state2 += coef * (hp - state2 / q)
        state  += coef * state2
        p[i] = state * env * 0.7
    }
}

fileprivate func synthLead(into p: UnsafeMutablePointer<Float>, frames: Int, freq: Float, shape: Shape) {
    synthBass(into: p, frames: frames, freq: freq, shape: shape)
}

fileprivate func synthPWMLead(into p: UnsafeMutablePointer<Float>, frames: Int, freq: Float) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        let pwm = 0.5 + 0.3 * sinf(2 * .pi * 3 * t)  // LFO on duty
        let phase = (freq * t).truncatingRemainder(dividingBy: 1)
        let raw: Float = phase < pwm ? 0.7 : -0.7
        p[i] = raw * envelope(i, of: frames, attack: 0.01, decay: 0.4)
    }
}

fileprivate func synthFMLead(into p: UnsafeMutablePointer<Float>, frames: Int,
                             freq: Float, ratio: Float, mod: Float) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        let modulator = sinf(2 * .pi * freq * ratio * t) * mod
        p[i] = sinf(2 * .pi * freq * t + modulator)
             * envelope(i, of: frames, attack: 0.005, decay: 0.5) * 0.7
    }
}

fileprivate func synthPad(into p: UnsafeMutablePointer<Float>, frames: Int,
                          freq: Float, layers: Int) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        var v: Float = 0
        for layer in 0..<layers {
            let detune = 1.0 + Float(layer - layers / 2) * 0.01
            v += sinf(2 * .pi * freq * detune * t) / Float(layers)
        }
        p[i] = v * envelope(i, of: frames, attack: 0.1, decay: 0.9) * 0.5
    }
}

fileprivate func synthBell(into p: UnsafeMutablePointer<Float>, frames: Int, freq: Float) {
    let partials: [(Float, Float)] = [(1, 1.0), (2.01, 0.5), (3.03, 0.3), (5.08, 0.2)]
    for i in 0..<frames {
        let t = Float(i) / 44100
        var v: Float = 0
        for (ratio, amp) in partials {
            v += sinf(2 * .pi * freq * ratio * t) * amp * expf(-t * 2)
        }
        p[i] = v * 0.5
    }
}

fileprivate func synthCowbell(into p: UnsafeMutablePointer<Float>, frames: Int) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        let a = sinf(2 * .pi * 540 * t)
        let b = sinf(2 * .pi * 800 * t)
        p[i] = (a + b) * expf(-t * 15) * 0.4
    }
}

fileprivate func synthRim(into p: UnsafeMutablePointer<Float>, frames: Int) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        p[i] = Float.random(in: -1...1) * expf(-t * 200) * 0.6
    }
}

fileprivate func synthShaker(into p: UnsafeMutablePointer<Float>, frames: Int) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        p[i] = Float.random(in: -1...1) * expf(-t * 45) * 0.3
    }
}

fileprivate func synthWoodBlock(into p: UnsafeMutablePointer<Float>, frames: Int) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        p[i] = sinf(2 * .pi * 1200 * t) * expf(-t * 80) * 0.6
    }
}

fileprivate func synthClick(into p: UnsafeMutablePointer<Float>, frames: Int) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        p[i] = sinf(2 * .pi * 2000 * t) * expf(-t * 400) * 0.8
    }
}

fileprivate func synthSweep(into p: UnsafeMutablePointer<Float>, frames: Int,
                            startFreq: Float, endFreq: Float) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        let pct = Float(i) / Float(frames)
        let f = startFreq + (endFreq - startFreq) * pct
        p[i] = sinf(2 * .pi * f * t) * envelope(i, of: frames, attack: 0.1, decay: 0.8)
    }
}

fileprivate func synthZap(into p: UnsafeMutablePointer<Float>, frames: Int) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        let pitch = 2000 * expf(-t * 15)
        p[i] = sinf(2 * .pi * pitch * t) * expf(-t * 8) * 0.5
    }
}

fileprivate func synthPulse(into p: UnsafeMutablePointer<Float>, frames: Int, freq: Float) {
    for i in 0..<frames {
        let t = Float(i) / 44100
        let phase = (freq * t).truncatingRemainder(dividingBy: 1)
        p[i] = (phase < 0.25 ? 0.7 : -0.7) * envelope(i, of: frames)
    }
}

fileprivate func synthMetal(into p: UnsafeMutablePointer<Float>, frames: Int) {
    let partials: [Float] = [247, 389, 563, 742, 899]
    for i in 0..<frames {
        let t = Float(i) / 44100
        var v: Float = 0
        for f in partials {
            v += sinf(2 * .pi * f * t) * expf(-t * Float.random(in: 3...8)) * 0.2
        }
        p[i] = v
    }
}
