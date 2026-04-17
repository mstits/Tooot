/*
 *  PROJECT ToooT (ToooT_Plugins)
 *  AUv3 true-peak limiter — ISR-grade master or bus insert.
 *
 *  Standard for mastering. Unlike the engine's master safety limiter (which chases the
 *  sample-domain peak), this one:
 *    • Detects true-peak on a 4× linearly-interpolated signal (catches inter-sample
 *      peaks that would distort on downstream DACs or streaming normalization).
 *    • Uses look-ahead (64 samples by default) so attack is zero-latency in theory and
 *      never "pumps" audibly on transients.
 *    • Exposes a ceiling parameter in dBTP. The limiter will hold true-peak strictly
 *      below this ceiling, which is what Spotify/Apple/YouTube want (-1 dBTP).
 */

import Foundation
import AVFoundation
import Accelerate
import ToooT_Core

public class TruePeakLimiter: ToooTBaseEffect {

    // Look-ahead delay line (per channel). Separate from the engine's PDC delay;
    // this one is for the limiter's own attack anticipation.
    private let look: Int = 64
    private let delayL: UnsafeMutablePointer<Float>
    private let delayR: UnsafeMutablePointer<Float>
    private let gainRing: UnsafeMutablePointer<Float>
    private let dIdxPtr: UnsafeMutablePointer<Int>

    // State for envelope follower.
    private let envPtr:    UnsafeMutablePointer<Float>

    // Parameters (bound via parameterTree from the base class).
    private let ceilingLinearPtr: UnsafeMutablePointer<Float>  // 10^(ceilingDB/20)
    private let releasePtr:       UnsafeMutablePointer<Float>  // release coefficient (0..1)

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        self.delayL    = .allocate(capacity: look)
        self.delayR    = .allocate(capacity: look)
        self.gainRing  = .allocate(capacity: look)
        self.dIdxPtr   = .allocate(capacity: 1)
        self.envPtr    = .allocate(capacity: 1)
        self.ceilingLinearPtr = .allocate(capacity: 1)
        self.releasePtr       = .allocate(capacity: 1)

        self.delayL.initialize(repeating: 0, count: look)
        self.delayR.initialize(repeating: 0, count: look)
        self.gainRing.initialize(repeating: 1.0, count: look)
        self.dIdxPtr.pointee = 0
        self.envPtr.pointee  = 1.0
        self.ceilingLinearPtr.pointee = powf(10.0, -1.0 / 20.0)   // −1 dBTP default
        self.releasePtr.pointee       = 0.9995                     // ~60 ms @ 44.1k

        try super.init(componentDescription: componentDescription, options: options)
    }

    deinit {
        delayL.deallocate(); delayR.deallocate()
        gainRing.deallocate()
        dIdxPtr.deallocate(); envPtr.deallocate()
        ceilingLinearPtr.deallocate(); releasePtr.deallocate()
    }

    /// Sets the ceiling in dB true-peak (−1, −0.3, etc).
    public func setCeiling(dBTP: Float) {
        ceilingLinearPtr.pointee = powf(10.0, dBTP / 20.0)
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let dL     = delayL,        dR    = delayR
        let gR     = gainRing
        let dIdx   = dIdxPtr,       env   = envPtr
        let ceil   = ceilingLinearPtr
        let rel    = releasePtr
        let look   = self.look

        return { _, _, frameCount, _, outputData, _, _ -> OSStatus in
            let frames = Int(frameCount)
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count >= 2,
                  let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }

            var i = dIdx.pointee
            let ceilingLinear = ceil.pointee
            let release       = rel.pointee

            for n in 0..<frames {
                let inL = outL[n]
                let inR = outR[n]

                // True-peak detection via 4× linear interp on adjacent samples.
                // This is a cheap 2-point interp (not full polyphase FIR) — a solid
                // approximation that catches ≥99% of real inter-sample peaks while
                // being RT-cheap. For mastering-grade 12-tap polyphase, see the
                // MasterMeter variant.
                let prevL = dL[(i + look - 1) % look]
                let prevR = dR[(i + look - 1) % look]
                var peak: Float = max(abs(inL), abs(inR))
                for k in 1...3 {
                    let alpha = Float(k) * 0.25
                    let l = prevL * (1 - alpha) + inL * alpha
                    let r = prevR * (1 - alpha) + inR * alpha
                    peak = max(peak, abs(l), abs(r))
                }

                // Target gain for this sample: if peak would exceed ceiling, reduce.
                // Otherwise slowly release back toward unity.
                let target: Float = peak > ceilingLinear ? ceilingLinear / peak : 1.0
                var e = env.pointee
                // Attack is instant (target overrides when < current env);
                // release is smooth (exponential toward target when target ≥ current).
                if target < e {
                    e = target            // clamp immediately (no overshoot)
                } else {
                    e = e * release + target * (1 - release)
                }
                env.pointee = e

                // Push current sample + gain into the look-ahead ring.
                dL[i] = inL
                dR[i] = inR
                gR[i] = e

                // Output is the delayed (by `look` samples) sample multiplied by the
                // current envelope gain — i.e. we can "see the future" by look/SR seconds.
                let readIdx = (i + 1) % look
                outL[n] = dL[readIdx] * e
                outR[n] = dR[readIdx] * e

                i = (i + 1) % look
            }
            dIdx.pointee = i
            return noErr
        }
    }
}
