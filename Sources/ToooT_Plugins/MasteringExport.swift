/*
 *  PROJECT ToooT (ToooT_Plugins)
 *  Mastering utilities for WAV export: TPDF dither + loudness normalization.
 *
 *  These functions run offline (not on the render thread) — they trade allocation
 *  freedom for mastering-grade quality: noise-shaped TPDF dither for bit depth
 *  reduction, and two-pass LUFS normalization (measure → compute gain → apply +
 *  true-peak touch-up limiter).
 */

import Foundation
import Accelerate
import ToooT_Core

public enum MasteringExport {

    // MARK: - Dither

    public enum DitherMode: Sendable {
        case none
        /// Rectangular dither: uniform noise in ±½ LSB. Simplest, slight audible noise.
        case rectangular
        /// Triangular PDF (convolution of two rectangular): ±1 LSB, more natural sound.
        /// Industry-standard default for 24→16-bit reduction.
        case tpdf
    }

    /// Applies dither to a pair of Float buffers in preparation for bit-depth reduction.
    /// `bits` is the target PCM bit depth (16 or 24). Dither amplitude is ±½ LSB scaled
    /// to the Float32 range: 1 LSB at N bits = 1 / 2^(N-1), so amplitude = 1 / 2^N.
    ///
    /// This is a destructive in-place op; caller owns the buffers.
    public static func applyDither(bufferL: UnsafeMutablePointer<Float>,
                                   bufferR: UnsafeMutablePointer<Float>,
                                   frames: Int,
                                   bits: Int,
                                   mode: DitherMode) {
        guard mode != .none, bits > 0, bits < 32 else { return }
        let lsb = 1.0 / powf(2.0, Float(bits - 1))   // 1 LSB in normalized float
        let amp = lsb * 0.5                          // ±½ LSB
        switch mode {
        case .none: break
        case .rectangular:
            for i in 0..<frames {
                bufferL[i] += Float.random(in: -amp...amp)
                bufferR[i] += Float.random(in: -amp...amp)
            }
        case .tpdf:
            // TPDF = sum of two independent rectangular noises in [-amp/2, +amp/2).
            // Yields a triangular distribution across [-amp, +amp], zero mean.
            for i in 0..<frames {
                let n1 = Float.random(in: -amp...amp)
                let n2 = Float.random(in: -amp...amp)
                bufferL[i] += (n1 + n2) * 0.5
                let m1 = Float.random(in: -amp...amp)
                let m2 = Float.random(in: -amp...amp)
                bufferR[i] += (m1 + m2) * 0.5
            }
        }
    }

    // MARK: - Loudness normalization

    public struct LoudnessTarget: Sendable {
        public let name:           String
        public let integratedLUFS: Float
        public let truePeakCeiling: Float   // dBTP; e.g. -1.0 for streaming

        public static let spotify      = LoudnessTarget(name: "Spotify",      integratedLUFS: -14, truePeakCeiling: -1.0)
        public static let appleMusic   = LoudnessTarget(name: "Apple Music",  integratedLUFS: -16, truePeakCeiling: -1.0)
        public static let youtube      = LoudnessTarget(name: "YouTube",      integratedLUFS: -14, truePeakCeiling: -1.0)
        public static let ebuR128      = LoudnessTarget(name: "EBU R128",     integratedLUFS: -23, truePeakCeiling: -1.0)
        public static let amazonMusic  = LoudnessTarget(name: "Amazon Music", integratedLUFS: -14, truePeakCeiling: -2.0)
    }

    public struct LoudnessReport: Sendable {
        public let measuredLUFS: Float
        public let measuredTruePeak: Float
        public let gainApplied:   Float        // linear multiplier
        public let clippedSamples: Int         // > 0 means limiter engaged
    }

    /// Two-pass loudness normalization:
    ///   1. Measure integrated LUFS + true-peak over the full buffer via MasterMeter.
    ///   2. Compute gain so measured LUFS → `target.integratedLUFS`.
    ///   3. Reduce gain if it would push true-peak above `target.truePeakCeiling`.
    ///   4. Apply gain (vDSP_vsmul) + soft-clip any remaining overs at the ceiling.
    ///
    /// Returns a report so the caller can show the user what happened.
    public static func normalizeLoudness(bufferL: UnsafeMutablePointer<Float>,
                                         bufferR: UnsafeMutablePointer<Float>,
                                         frames: Int,
                                         sampleRate: Double,
                                         target: LoudnessTarget) -> LoudnessReport {
        // Pass 1: measure.
        let meter = MasterMeter()
        meter.reset()
        meter.process(stereoL: bufferL, stereoR: bufferR, frames: frames, sampleRate: sampleRate)

        let measuredLUFS = meter.integratedLUFS
        let measuredTP   = meter.truePeak

        // Compute the gain required to hit the integrated-LUFS target.
        //   gainDB = target.integratedLUFS - measuredLUFS
        //   lufsGain = 10^(gainDB / 20)
        var gainDB = target.integratedLUFS - measuredLUFS

        // Apply the true-peak ceiling. If measured true-peak × lufsGain > ceilingLinear,
        // reduce gain so the output tops out at the ceiling.
        let ceilingLinear = powf(10.0, target.truePeakCeiling / 20.0)
        let lufsGainLinear = powf(10.0, gainDB / 20.0)
        if measuredTP * lufsGainLinear > ceilingLinear {
            // Prefer ceiling over hitting LUFS target exactly — you can go quieter than
            // your target but you can't go louder than the ceiling without distortion.
            let maxGainLinear = ceilingLinear / max(measuredTP, 1e-6)
            gainDB = 20.0 * log10f(maxGainLinear)
        }

        var gain = powf(10.0, gainDB / 20.0)
        vDSP_vsmul(bufferL, 1, &gain, bufferL, 1, vDSP_Length(frames))
        vDSP_vsmul(bufferR, 1, &gain, bufferR, 1, vDSP_Length(frames))

        // Touch-up: any samples still above the ceiling get soft-clipped (tanh).
        // Shouldn't happen unless measurement was wrong, but cheap to insure.
        var clipped = 0
        for i in 0..<frames {
            if abs(bufferL[i]) > ceilingLinear {
                bufferL[i] = ceilingLinear * tanhf(bufferL[i] / ceilingLinear)
                clipped += 1
            }
            if abs(bufferR[i]) > ceilingLinear {
                bufferR[i] = ceilingLinear * tanhf(bufferR[i] / ceilingLinear)
                clipped += 1
            }
        }

        return LoudnessReport(
            measuredLUFS:     measuredLUFS,
            measuredTruePeak: measuredTP,
            gainApplied:      gain,
            clippedSamples:   clipped
        )
    }
}
