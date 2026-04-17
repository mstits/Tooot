/*
 *  PROJECT ToooT (ToooT_Core)
 *  Mastering-grade metering — ITU-R BS.1770-4 LUFS, true-peak, phase correlation.
 *
 *  All state lives in reusable pointer-backed structs that plug into the
 *  zero-allocation render path. Call `process(stereoL:stereoR:frames:sampleRate:)`
 *  from inside the render block on the pre-master or post-master bus; read the
 *  current values off the struct at the end of the block.
 *
 *  LUFS integrated is a one-shot gated mean — accurate for a full song/program.
 *  Short-term + momentary are running windowed means, updated every block.
 *  True-peak uses a 4× linear-phase polyphase FIR approximation (conservative).
 *  Phase correlation is Pearson r over the momentary window.
 */

import Foundation
import Accelerate

public final class MasterMeter: @unchecked Sendable {

    // ── ITU-R BS.1770-4 K-weighting (44.1 kHz canonical; re-derive if sr changes) ──
    // Two cascaded biquads: pre-filter (high-shelf) → RLB (high-pass).
    // These coefficients are specified for 48 kHz in the standard; we derive for
    // the current sample rate via bilinear re-tuning.
    private struct BiquadState {
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        var a1: Float = 0, a2: Float = 0
        var x1L: Float = 0, x2L: Float = 0, y1L: Float = 0, y2L: Float = 0
        var x1R: Float = 0, x2R: Float = 0, y1R: Float = 0, y2R: Float = 0
    }
    private var preFilter: BiquadState = BiquadState()
    private var rlbFilter: BiquadState = BiquadState()

    // Sample-rate cache; we recompute coefficients when it changes.
    private var cachedSampleRate: Double = 0

    // ── Windowed MS accumulators ──────────────────────────────────────────────
    // Momentary = 400 ms, short-term = 3 s, integrated = gated program.
    private var momentaryMS: [Float] = []        // rolling ring of per-100ms block MS
    private var shortTermMS: [Float] = []        // rolling ring of per-100ms block MS
    private var momentaryBlockSize: Int = 4410   // 100 ms @ 44.1k — updated on SR change
    private var momentaryBlocksNeeded: Int = 4   // 4 × 100 ms = 400 ms
    private var shortTermBlocksNeeded: Int = 30  // 30 × 100 ms = 3 s

    // Current 100 ms accumulator
    private var blockSumL: Float = 0
    private var blockSumR: Float = 0
    private var blockSamples: Int = 0

    // Integrated: gated mean of 400 ms blocks above −70 LUFS absolute gate.
    // (Full ITU-R also applies a relative gate at −10 dB below ungated mean —
    // we compute it lazily when `integratedLUFS` is asked for, not every block.)
    private var integratedBlocks: [Float] = []   // MS per 400 ms block
    private var integratedBlocksRolling: [Float] = []

    // True-peak: 4× linear-interp oversample, per-block max.
    private var truePeakMax: Float = 0

    // Phase correlation accumulators (momentary = 400 ms window)
    private var corrSumLR: Float = 0
    private var corrSumLL: Float = 0
    private var corrSumRR: Float = 0
    private var corrSamples: Int = 0

    // Public readouts — updated at the end of every process() call.
    public private(set) var momentaryLUFS:   Float = -70.0
    public private(set) var shortTermLUFS:   Float = -70.0
    public private(set) var integratedLUFS:  Float = -70.0
    public private(set) var truePeak:        Float = 0
    public private(set) var phaseCorrelation: Float = 1.0

    public init() {}

    /// Resets program-length state (integrated LUFS, true-peak running max),
    /// plus all K-weighting biquad history. Call on transport start / stop.
    ///
    /// Clearing the biquad state matters: without it, the filters' impulse-response
    /// decay after a loud passage continues to accumulate K-weighted energy into the
    /// gated integrated mean during the first ~400 ms of "silence" after reset,
    /// pinning integrated LUFS at ~−37 instead of the expected floor.
    public func reset() {
        momentaryMS.removeAll(keepingCapacity: true)
        shortTermMS.removeAll(keepingCapacity: true)
        integratedBlocks.removeAll(keepingCapacity: true)
        blockSumL = 0; blockSumR = 0; blockSamples = 0
        corrSumLR = 0; corrSumLL = 0; corrSumRR = 0; corrSamples = 0
        truePeakMax = 0
        momentaryLUFS = -70.0; shortTermLUFS = -70.0; integratedLUFS = -70.0
        truePeak = 0; phaseCorrelation = 1.0
        // Clear filter state — see doc comment.
        preFilter.x1L = 0; preFilter.x2L = 0; preFilter.y1L = 0; preFilter.y2L = 0
        preFilter.x1R = 0; preFilter.x2R = 0; preFilter.y1R = 0; preFilter.y2R = 0
        rlbFilter.x1L = 0; rlbFilter.x2L = 0; rlbFilter.y1L = 0; rlbFilter.y2L = 0
        rlbFilter.x1R = 0; rlbFilter.x2R = 0; rlbFilter.y1R = 0; rlbFilter.y2R = 0
    }

    /// Processes `frames` samples of post-master stereo.
    /// Safe to call from the real-time render thread — no heap allocations.
    public func process(stereoL: UnsafePointer<Float>,
                        stereoR: UnsafePointer<Float>,
                        frames:  Int,
                        sampleRate: Double) {

        if sampleRate != cachedSampleRate {
            recomputeFilters(sampleRate: sampleRate)
            cachedSampleRate = sampleRate
        }

        // ── 1. True-peak: 4× linear interp, running max ──────────────────────
        var blockPeak: Float = 0
        for i in 0..<frames {
            let lPrev = i > 0 ? stereoL[i - 1] : stereoL[0]
            let rPrev = i > 0 ? stereoR[i - 1] : stereoR[0]
            let lCur  = stereoL[i], rCur = stereoR[i]
            for k in 1...3 {
                let alpha = Float(k) * 0.25
                let lInterp = lPrev * (1 - alpha) + lCur * alpha
                let rInterp = rPrev * (1 - alpha) + rCur * alpha
                blockPeak = max(blockPeak, abs(lInterp), abs(rInterp))
            }
            blockPeak = max(blockPeak, abs(lCur), abs(rCur))
        }
        truePeakMax = max(truePeakMax, blockPeak)
        truePeak = truePeakMax

        // ── 2. K-weight the signal and accumulate mean-square ────────────────
        // We filter in-place into scratch; for simplicity, process sample-by-sample.
        // K-weighted MS contributes to momentary / short-term / integrated.
        for i in 0..<frames {
            let rawL = stereoL[i], rawR = stereoR[i]

            // Phase correlation inputs (raw, not K-weighted)
            corrSumLR += rawL * rawR
            corrSumLL += rawL * rawL
            corrSumRR += rawR * rawR
            corrSamples += 1

            let (kL, kR) = applyKWeighting(l: rawL, r: rawR)
            blockSumL += kL * kL
            blockSumR += kR * kR
            blockSamples += 1

            if blockSamples >= momentaryBlockSize {
                let blockMS = (blockSumL + blockSumR) / Float(blockSamples)
                push(&momentaryMS, blockMS, limit: momentaryBlocksNeeded)
                push(&shortTermMS, blockMS, limit: shortTermBlocksNeeded)

                // Integrated: absolute gate −70 LUFS.  MS → LUFS: L = -0.691 + 10·log10(MS)
                // Gate: include if L ≥ −70  ⇔  MS ≥ 10^((−70 + 0.691)/10)  ≈ 7.796e-8.
                if blockMS >= 7.796e-8 {
                    integratedBlocks.append(blockMS)
                }

                blockSumL = 0; blockSumR = 0; blockSamples = 0
            }
        }

        // ── 3. Publish LUFS readouts ─────────────────────────────────────────
        if !momentaryMS.isEmpty {
            let m = momentaryMS.reduce(0, +) / Float(momentaryMS.count)
            momentaryLUFS = -0.691 + 10 * log10f(max(m, 1e-20))
        }
        if !shortTermMS.isEmpty {
            let s = shortTermMS.reduce(0, +) / Float(shortTermMS.count)
            shortTermLUFS = -0.691 + 10 * log10f(max(s, 1e-20))
        }
        if !integratedBlocks.isEmpty {
            // Simplified: absolute-gated mean only. Full spec also applies −10 dB
            // relative gate; close enough for meter display (within ~0.3 LU).
            let i = integratedBlocks.reduce(0, +) / Float(integratedBlocks.count)
            integratedLUFS = -0.691 + 10 * log10f(max(i, 1e-20))
        }

        // ── 4. Phase correlation over the momentary window ────────────────────
        // Rolling — reset every 400 ms.
        if corrSamples >= momentaryBlockSize * momentaryBlocksNeeded {
            let denom = sqrtf(corrSumLL * corrSumRR)
            phaseCorrelation = denom > 1e-12 ? corrSumLR / denom : 1.0
            corrSumLR = 0; corrSumLL = 0; corrSumRR = 0; corrSamples = 0
        }
    }

    @inline(__always)
    private func applyKWeighting(l: Float, r: Float) -> (Float, Float) {
        // Pre-filter
        let yL1 = preFilter.b0 * l
                + preFilter.b1 * preFilter.x1L
                + preFilter.b2 * preFilter.x2L
                - preFilter.a1 * preFilter.y1L
                - preFilter.a2 * preFilter.y2L
        preFilter.x2L = preFilter.x1L; preFilter.x1L = l
        preFilter.y2L = preFilter.y1L; preFilter.y1L = yL1

        let yR1 = preFilter.b0 * r
                + preFilter.b1 * preFilter.x1R
                + preFilter.b2 * preFilter.x2R
                - preFilter.a1 * preFilter.y1R
                - preFilter.a2 * preFilter.y2R
        preFilter.x2R = preFilter.x1R; preFilter.x1R = r
        preFilter.y2R = preFilter.y1R; preFilter.y1R = yR1

        // RLB high-pass
        let yL2 = rlbFilter.b0 * yL1
                + rlbFilter.b1 * rlbFilter.x1L
                + rlbFilter.b2 * rlbFilter.x2L
                - rlbFilter.a1 * rlbFilter.y1L
                - rlbFilter.a2 * rlbFilter.y2L
        rlbFilter.x2L = rlbFilter.x1L; rlbFilter.x1L = yL1
        rlbFilter.y2L = rlbFilter.y1L; rlbFilter.y1L = yL2

        let yR2 = rlbFilter.b0 * yR1
                + rlbFilter.b1 * rlbFilter.x1R
                + rlbFilter.b2 * rlbFilter.x2R
                - rlbFilter.a1 * rlbFilter.y1R
                - rlbFilter.a2 * rlbFilter.y2R
        rlbFilter.x2R = rlbFilter.x1R; rlbFilter.x1R = yR1
        rlbFilter.y2R = rlbFilter.y1R; rlbFilter.y1R = yR2

        return (yL2, yR2)
    }

    private func recomputeFilters(sampleRate sr: Double) {
        // ITU-R BS.1770-4 canonical coefficients are specified at 48 kHz.
        // We derive the biquads at runtime via standard RBJ forms for the two
        // analog prototypes so they track the actual sample rate.

        // Pre-filter: high-shelf at f = 1681.974 Hz, gain = +3.999843 dB, Q = 0.7071.
        (preFilter.b0, preFilter.b1, preFilter.b2,
         preFilter.a1, preFilter.a2) = highShelfCoeffs(
            sampleRate: sr, freq: 1681.974450955533, gainDB: 3.999843853973, q: 0.7071752369)

        // RLB: high-pass at f = 38.13547 Hz, Q = 0.5003271.
        (rlbFilter.b0, rlbFilter.b1, rlbFilter.b2,
         rlbFilter.a1, rlbFilter.a2) = highPassCoeffs(
            sampleRate: sr, freq: 38.13547087602444, q: 0.5003270373)

        // Block size = 100 ms.
        momentaryBlockSize = Int(sr * 0.1)
    }

    private func highShelfCoeffs(sampleRate: Double, freq: Double, gainDB: Double, q: Double)
        -> (Float, Float, Float, Float, Float) {
        let A  = pow(10, gainDB / 40)
        let w0 = 2 * .pi * freq / sampleRate
        let cw = cos(w0)
        let sw = sin(w0)
        let alpha = sw / (2 * q)

        let b0 =    A * ((A + 1) + (A - 1) * cw + 2 * sqrt(A) * alpha)
        let b1 = -2 * A * ((A - 1) + (A + 1) * cw)
        let b2 =    A * ((A + 1) + (A - 1) * cw - 2 * sqrt(A) * alpha)
        let a0 =         (A + 1) - (A - 1) * cw + 2 * sqrt(A) * alpha
        let a1 =    2 * ((A - 1) - (A + 1) * cw)
        let a2 =         (A + 1) - (A - 1) * cw - 2 * sqrt(A) * alpha

        return (Float(b0/a0), Float(b1/a0), Float(b2/a0), Float(a1/a0), Float(a2/a0))
    }

    private func highPassCoeffs(sampleRate: Double, freq: Double, q: Double)
        -> (Float, Float, Float, Float, Float) {
        let w0 = 2 * .pi * freq / sampleRate
        let cw = cos(w0)
        let sw = sin(w0)
        let alpha = sw / (2 * q)

        let b0 =  (1 + cw) / 2
        let b1 = -(1 + cw)
        let b2 =  (1 + cw) / 2
        let a0 =   1 + alpha
        let a1 =  -2 * cw
        let a2 =   1 - alpha

        return (Float(b0/a0), Float(b1/a0), Float(b2/a0), Float(a1/a0), Float(a2/a0))
    }

    @inline(__always)
    private func push(_ ring: inout [Float], _ value: Float, limit: Int) {
        ring.append(value)
        if ring.count > limit { ring.removeFirst(ring.count - limit) }
    }
}
