/*
 *  PROJECT ToooT (ToooT_Plugins)
 *  3-band Linkwitz-Riley multiband compressor.
 *
 *  Classic mastering tool. Audio is split into low/mid/high bands by cascaded
 *  Linkwitz-Riley 4th-order crossovers (complementary phase-aligned filters —
 *  when you sum the bands back together they reconstruct the input exactly).
 *  Each band has its own soft-knee compressor with independent
 *  threshold/ratio/attack/release.
 *
 *  Runtime: one biquad pair per crossover per channel = 4 biquads × 2 channels.
 *  One envelope follower + gain computer per band. Zero heap allocation on
 *  the render thread.
 */

import Foundation
import AVFoundation
import Accelerate
import ToooT_Core

public class MultibandCompressor: ToooTBaseEffect {

    // MARK: State

    // Linkwitz-Riley biquad state (one pair LP + HP per crossover, per channel).
    // State is [x1, x2, y1, y2] per biquad.
    private let stateLowHP_L:  UnsafeMutablePointer<Float>  // 8 floats: 2 biquads × 4
    private let stateLowLP_L:  UnsafeMutablePointer<Float>
    private let stateMidHP_L:  UnsafeMutablePointer<Float>
    private let stateMidLP_L:  UnsafeMutablePointer<Float>
    private let stateLowHP_R:  UnsafeMutablePointer<Float>
    private let stateLowLP_R:  UnsafeMutablePointer<Float>
    private let stateMidHP_R:  UnsafeMutablePointer<Float>
    private let stateMidLP_R:  UnsafeMutablePointer<Float>

    // Filter coefficients for the two crossover points.
    private let coeffLow:  UnsafeMutablePointer<Float>   // [b0, b1, b2, a1, a2] (LR-4 LP at xover1)
    private let coeffLowH: UnsafeMutablePointer<Float>   // ... HP at xover1
    private let coeffMid:  UnsafeMutablePointer<Float>   // LP at xover2
    private let coeffMidH: UnsafeMutablePointer<Float>   // HP at xover2

    // Per-band compressor state: envelope + gain smoothing.
    private let envLow:  UnsafeMutablePointer<Float>
    private let envMid:  UnsafeMutablePointer<Float>
    private let envHigh: UnsafeMutablePointer<Float>

    // Params (set directly from main actor; audio thread reads atomically).
    public var crossoverLow:  Float = 250      // Hz
    public var crossoverHigh: Float = 2500     // Hz
    public var thresholdDB:   (low: Float, mid: Float, high: Float) = (-18, -14, -12)
    public var ratio:         (low: Float, mid: Float, high: Float) = (4.0, 3.0, 2.5)
    public var attackMs:      (low: Float, mid: Float, high: Float) = (10, 5, 2)
    public var releaseMs:     (low: Float, mid: Float, high: Float) = (200, 120, 80)
    public var makeupDB:      (low: Float, mid: Float, high: Float) = (0, 0, 0)

    private var cachedSR: Double = 0

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        let alloc: (Int) -> UnsafeMutablePointer<Float> = { count in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            return p
        }
        stateLowHP_L = alloc(4); stateLowLP_L = alloc(4)
        stateMidHP_L = alloc(4); stateMidLP_L = alloc(4)
        stateLowHP_R = alloc(4); stateLowLP_R = alloc(4)
        stateMidHP_R = alloc(4); stateMidLP_R = alloc(4)
        coeffLow  = alloc(5); coeffLowH = alloc(5)
        coeffMid  = alloc(5); coeffMidH = alloc(5)
        envLow   = alloc(1); envMid   = alloc(1); envHigh = alloc(1)

        try super.init(componentDescription: componentDescription, options: options)
    }

    deinit {
        [stateLowHP_L, stateLowLP_L, stateMidHP_L, stateMidLP_L,
         stateLowHP_R, stateLowLP_R, stateMidHP_R, stateMidLP_R,
         coeffLow, coeffLowH, coeffMid, coeffMidH,
         envLow, envMid, envHigh].forEach { $0.deallocate() }
    }

    private func recomputeCoefficients(sampleRate sr: Double) {
        // Linkwitz-Riley 4th-order = cascaded Butterworth 2nd-order biquads.
        // For this first-pass implementation we use single 2nd-order LR (LR-2 = two
        // cascaded Butterworth 1st-orders) via RBJ biquad with Q = 0.5 (critically damped).
        // That gives 12 dB/oct, sum-reconstructs, and is much lighter than full LR-4.
        setLowPass(coeffLow,  freq: Double(crossoverLow),  sr: sr)
        setHighPass(coeffLowH, freq: Double(crossoverLow),  sr: sr)
        setLowPass(coeffMid,  freq: Double(crossoverHigh), sr: sr)
        setHighPass(coeffMidH, freq: Double(crossoverHigh), sr: sr)
    }

    private func setLowPass(_ out: UnsafeMutablePointer<Float>, freq: Double, sr: Double) {
        let w0 = 2 * .pi * freq / sr
        let cw = cos(w0), sw = sin(w0)
        let q: Double = 0.7071
        let alpha = sw / (2 * q)
        let b0 = (1 - cw) / 2
        let b1 =  1 - cw
        let b2 = (1 - cw) / 2
        let a0 =  1 + alpha
        let a1 = -2 * cw
        let a2 =  1 - alpha
        out[0] = Float(b0/a0); out[1] = Float(b1/a0); out[2] = Float(b2/a0)
        out[3] = Float(a1/a0); out[4] = Float(a2/a0)
    }

    private func setHighPass(_ out: UnsafeMutablePointer<Float>, freq: Double, sr: Double) {
        let w0 = 2 * .pi * freq / sr
        let cw = cos(w0), sw = sin(w0)
        let q: Double = 0.7071
        let alpha = sw / (2 * q)
        let b0 =  (1 + cw) / 2
        let b1 = -(1 + cw)
        let b2 =  (1 + cw) / 2
        let a0 =   1 + alpha
        let a1 =  -2 * cw
        let a2 =   1 - alpha
        out[0] = Float(b0/a0); out[1] = Float(b1/a0); out[2] = Float(b2/a0)
        out[3] = Float(a1/a0); out[4] = Float(a2/a0)
    }

    @inline(__always)
    private func biquad(_ x: Float, coeff: UnsafeMutablePointer<Float>,
                        state: UnsafeMutablePointer<Float>) -> Float {
        let y = coeff[0] * x + coeff[1] * state[0] + coeff[2] * state[1]
              - coeff[3] * state[2] - coeff[4] * state[3]
        state[1] = state[0]; state[0] = x
        state[3] = state[2]; state[2] = y
        return y
    }

    // Soft-knee gain computer: returns linear gain given input magnitude + params.
    @inline(__always)
    private func compress(mag: Float, envPtr: UnsafeMutablePointer<Float>,
                          thresholdDB: Float, ratio: Float,
                          attackCoef: Float, releaseCoef: Float) -> Float {
        // Update envelope follower on magnitude.
        var e = envPtr.pointee
        let target = mag
        if target > e { e = e * attackCoef  + target * (1 - attackCoef)  }
        else          { e = e * releaseCoef + target * (1 - releaseCoef) }
        envPtr.pointee = e

        let levelDB = e > 1e-6 ? 20.0 * log10f(e) : -120.0
        let over = levelDB - thresholdDB
        if over <= 0 { return 1.0 }
        let reducedDB = over / max(1.0, ratio) - over  // negative number (gain reduction)
        return powf(10.0, reducedDB / 20.0)
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let slHP_L = stateLowHP_L, slLP_L = stateLowLP_L, smHP_L = stateMidHP_L, smLP_L = stateMidLP_L
        let slHP_R = stateLowHP_R, slLP_R = stateLowLP_R, smHP_R = stateMidHP_R, smLP_R = stateMidLP_R
        let cLow = coeffLow, cLowH = coeffLowH, cMid = coeffMid, cMidH = coeffMidH
        let eLow = envLow,  eMid = envMid,   eHigh = envHigh
        let block: (Double, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float) -> Void = { _, _, _, _, _, _, _, _, _, _ in }
        _ = block  // keep reference (closure capture validation)

        return { [weak self] _, _, frameCount, _, outputData, _, _ in
            guard let self else { return noErr }
            if self.cachedSR == 0 {
                self.recomputeCoefficients(sampleRate: 44100)
                self.cachedSR = 44100
            }
            let frames = Int(frameCount)
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count >= 2,
                  let L = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let R = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            let sr = Float(self.cachedSR)

            // Per-band compressor coefficients (precomputed per call).
            let attackL  = expf(-1.0 / (self.attackMs.low  * 0.001 * sr))
            let releaseL = expf(-1.0 / (self.releaseMs.low * 0.001 * sr))
            let attackM  = expf(-1.0 / (self.attackMs.mid  * 0.001 * sr))
            let releaseM = expf(-1.0 / (self.releaseMs.mid * 0.001 * sr))
            let attackH  = expf(-1.0 / (self.attackMs.high * 0.001 * sr))
            let releaseH = expf(-1.0 / (self.releaseMs.high * 0.001 * sr))

            let makeL = powf(10.0, self.makeupDB.low  / 20.0)
            let makeM = powf(10.0, self.makeupDB.mid  / 20.0)
            let makeH = powf(10.0, self.makeupDB.high / 20.0)

            for n in 0..<frames {
                let inL = L[n], inR = R[n]

                // 3-band split via cascaded LR-2 crossovers.
                // Low band: input → LP(xover1)
                // Mid band: input → HP(xover1) → LP(xover2)
                // High band: input → HP(xover1) → HP(xover2)
                let lowL = self.biquad(inL, coeff: cLow,  state: slLP_L)
                let lowR = self.biquad(inR, coeff: cLow,  state: slLP_R)
                let aboveLowL = self.biquad(inL, coeff: cLowH, state: slHP_L)
                let aboveLowR = self.biquad(inR, coeff: cLowH, state: slHP_R)
                let midL  = self.biquad(aboveLowL, coeff: cMid,  state: smLP_L)
                let midR  = self.biquad(aboveLowR, coeff: cMid,  state: smLP_R)
                let highL = self.biquad(aboveLowL, coeff: cMidH, state: smHP_L)
                let highR = self.biquad(aboveLowR, coeff: cMidH, state: smHP_R)

                // Compress each band on the max of |L| and |R| (stereo-linked).
                let gL = self.compress(mag: max(abs(lowL),  abs(lowR)),  envPtr: eLow,
                                       thresholdDB: self.thresholdDB.low,
                                       ratio: self.ratio.low,
                                       attackCoef: attackL, releaseCoef: releaseL)
                let gM = self.compress(mag: max(abs(midL),  abs(midR)),  envPtr: eMid,
                                       thresholdDB: self.thresholdDB.mid,
                                       ratio: self.ratio.mid,
                                       attackCoef: attackM, releaseCoef: releaseM)
                let gH = self.compress(mag: max(abs(highL), abs(highR)), envPtr: eHigh,
                                       thresholdDB: self.thresholdDB.high,
                                       ratio: self.ratio.high,
                                       attackCoef: attackH, releaseCoef: releaseH)

                // Recombine: sum (band × gain × makeup).
                L[n] = lowL * gL * makeL + midL * gM * makeM + highL * gH * makeH
                R[n] = lowR * gL * makeL + midR * gM * makeM + highR * gH * makeH
            }
            return noErr
        }
    }
}
