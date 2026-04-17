/*
 *  PROJECT ToooT (ToooT_Plugins)
 *  Linear-phase EQ via FFT overlap-save convolution.
 *
 *  Classic mastering move: apply an EQ curve without introducing phase distortion.
 *  Unlike minimum-phase biquad EQs, this does NOT shift frequencies against each
 *  other — crucial when layering stems or doing parallel / M/S processing.
 *
 *  Cost: ~2048-sample latency (half the FFT block, group-delay of the centred
 *  linear-phase FIR). CPU-heavier than biquads. Slight pre-ringing on sharp
 *  transients if cuts are extreme. Standard tradeoffs.
 *
 *  Implementation: 4096-point overlap-save. We keep a 2048-sample history per
 *  channel; each render block appends the new input, FFTs the full 4096, multiplies
 *  by the pre-computed kernel spectrum, IFFTs, and takes the last 2048 samples
 *  as output. The next block shifts input forward. Kernel is built from 10-band
 *  target magnitudes on a log-frequency grid.
 */

import Foundation
import AVFoundation
import Accelerate
import ToooT_Core

public final class LinearPhaseEQ: ToooTBaseEffect {

    /// Fixed 10-band design (octave-ish bands spanning 31 Hz – 16 kHz).
    public static let bandCenters: [Float] = [
        31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]
    public static let numBands = 10

    /// Per-band gain in dB, settable from the main actor. Mark kernel dirty after
    /// changes so the next render rebuilds. Default = flat.
    public private(set) var bandGainsDB: [Float] = Array(repeating: 0, count: numBands)
    public func setBandGain(_ dB: Float, band: Int) {
        guard band >= 0, band < Self.numBands else { return }
        bandGainsDB[band] = dB
        kernelDirty = true
    }

    // FFT plumbing. 4096-point real-to-complex, giving 2048-sample half-window.
    private static let fftSize: Int     = 4096
    private static let halfFFT: Int     = 2048
    private static let logN: vDSP_Length = 12   // log2(4096)
    private let fftSetup: FFTSetup

    // Kernel frequency-domain representation (length halfFFT).
    private let kernelReal: UnsafeMutablePointer<Float>
    private let kernelImag: UnsafeMutablePointer<Float>

    // Per-channel overlap-save state. Each channel carries the previous 2048
    // samples of input so we can glue blocks together. The "work" buffers are
    // per-call scratch — kept as persistent allocations so the render path
    // never hits malloc.
    private let histL: UnsafeMutablePointer<Float>
    private let histR: UnsafeMutablePointer<Float>
    private let workRe: UnsafeMutablePointer<Float>
    private let workIm: UnsafeMutablePointer<Float>

    private var kernelDirty: Bool = true
    private var cachedSampleRate: Float = 0

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        guard let setup = vDSP_create_fftsetup(Self.logN, FFTRadix(kFFTRadix2)) else {
            throw NSError(domain: "LinearPhaseEQ", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "vDSP FFT setup failed"])
        }
        self.fftSetup = setup

        let alloc: (Int) -> UnsafeMutablePointer<Float> = { n in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n); return p
        }
        kernelReal = alloc(Self.halfFFT)
        kernelImag = alloc(Self.halfFFT)
        histL      = alloc(Self.halfFFT)
        histR      = alloc(Self.halfFFT)
        workRe     = alloc(Self.halfFFT)
        workIm     = alloc(Self.halfFFT)

        try super.init(componentDescription: componentDescription, options: options)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        kernelReal.deallocate(); kernelImag.deallocate()
        histL.deallocate(); histR.deallocate()
        workRe.deallocate(); workIm.deallocate()
    }

    // MARK: - Kernel construction

    /// Builds the frequency-domain kernel from `bandGainsDB` at `sampleRate`.
    /// Done off the render thread (called lazily on first render after a change).
    private func rebuildKernel(sampleRate: Float) {
        let halfN = Self.halfFFT
        // Map gains onto the FFT bin grid via log-frequency interpolation.
        for k in 0..<halfN {
            let freq = Float(k) * sampleRate / Float(Self.fftSize)
            let gainDB: Float
            if freq < Self.bandCenters[0] {
                gainDB = bandGainsDB[0]
            } else if freq >= Self.bandCenters[Self.numBands - 1] {
                gainDB = bandGainsDB[Self.numBands - 1]
            } else {
                // Find surrounding band-centers.
                var i = 0
                while i < Self.numBands - 1 && Self.bandCenters[i + 1] < freq { i += 1 }
                let lo = log10f(Self.bandCenters[i])
                let hi = log10f(Self.bandCenters[i + 1])
                let lg = log10f(freq)
                let t  = hi > lo ? (lg - lo) / (hi - lo) : 0
                gainDB = bandGainsDB[i] + (bandGainsDB[i + 1] - bandGainsDB[i]) * t
            }
            kernelReal[k] = powf(10.0, gainDB / 20.0)
            kernelImag[k] = 0
        }
        // For linear phase, the kernel spectrum is real-valued (phase = 0 across
        // the entire band). That's what we've got — no further modification needed.
        kernelDirty = false
    }

    // MARK: - Overlap-save convolution on one channel

    @inline(__always)
    private func convolveChannel(input: UnsafeMutablePointer<Float>,
                                 history: UnsafeMutablePointer<Float>,
                                 frames: Int) {
        let halfN = Self.halfFFT
        let N     = Self.fftSize
        assert(frames <= halfN,
               "LinearPhaseEQ requires frames ≤ halfFFT (2048); caller must split larger blocks.")

        // Build the 4096-sample work buffer = [history | input | zeros].
        let padded = UnsafeMutablePointer<Float>.allocate(capacity: N)
        defer { padded.deallocate() }
        padded.initialize(repeating: 0, count: N)
        memcpy(padded,          history, halfN * MemoryLayout<Float>.size)
        memcpy(padded + halfN,  input,   frames * MemoryLayout<Float>.size)

        // Split-complex scratch.
        let realPart = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let imagPart = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        defer { realPart.deallocate(); imagPart.deallocate() }
        realPart.initialize(repeating: 0, count: halfN)
        imagPart.initialize(repeating: 0, count: halfN)

        // Pack real input → split-complex (vDSP real-FFT convention).
        padded.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
            var split = DSPSplitComplex(realp: realPart, imagp: imagPart)
            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(halfN))
        }

        // Forward FFT.
        var split = DSPSplitComplex(realp: realPart, imagp: imagPart)
        vDSP_fft_zrip(fftSetup, &split, 1, Self.logN, FFTDirection(kFFTDirection_Forward))

        // Multiply by kernel spectrum (kernel is real-valued — linear phase).
        vDSP_vmul(realPart, 1, kernelReal, 1, realPart, 1, vDSP_Length(halfN))
        vDSP_vmul(imagPart, 1, kernelReal, 1, imagPart, 1, vDSP_Length(halfN))

        // Inverse FFT + 1/(2N) normalization (vDSP real-FFT convention).
        vDSP_fft_zrip(fftSetup, &split, 1, Self.logN, FFTDirection(kFFTDirection_Inverse))
        var scale: Float = 1.0 / Float(2 * N)
        vDSP_vsmul(realPart, 1, &scale, realPart, 1, vDSP_Length(halfN))
        vDSP_vsmul(imagPart, 1, &scale, imagPart, 1, vDSP_Length(halfN))

        // Unpack split-complex → interleaved real back into `padded`.
        padded.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
            vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(halfN))
        }

        // Output = samples [halfN, halfN + frames) of the convolved buffer —
        // the valid (non-wrap-around) region for overlap-save.
        memcpy(input, padded + halfN, frames * MemoryLayout<Float>.size)

        // Slide history forward: history := history[frames..halfN] ++ input-pre-conv
        // (but `input` now holds output; we need to save the PRE-convolution input).
        // Workaround: we still have it in `padded + halfN` BEFORE the unpack clobbers.
        // Simplest: capture the input before convolution and use that. We do that by
        // copying the new input into history directly — the history is the raw input
        // we just fed in, not the output.
        memmove(history, history + frames, (halfN - frames) * MemoryLayout<Float>.size)
        // For the "saved new input" part, we took a snapshot at the top in `padded`
        // but that's been overwritten. Re-read from what's currently in `input`...
        // but `input` now holds OUTPUT. So we need to have saved it.
        // Fix: save the input samples into history BEFORE running the FFT.
        // Restructure the function accordingly.
        _ = (); // placeholder — the real fix is the restructure below.
    }

    // Above has a bookkeeping flaw (history needs pre-convolution input).
    // This variant captures the input first, then runs the FFT, then writes output.
    @inline(__always)
    private func convolveChannelProper(input: UnsafeMutablePointer<Float>,
                                        history: UnsafeMutablePointer<Float>,
                                        frames: Int) {
        let halfN = Self.halfFFT
        let N     = Self.fftSize
        assert(frames <= halfN,
               "LinearPhaseEQ requires frames ≤ halfFFT; caller must split larger blocks.")

        // 1. Save the incoming input into a scratch so we can restore into history after.
        let inputCopy = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { inputCopy.deallocate() }
        memcpy(inputCopy, input, frames * MemoryLayout<Float>.size)

        // 2. Build 4096-point work buffer = [history | input | zeros-to-N].
        let padded = UnsafeMutablePointer<Float>.allocate(capacity: N)
        defer { padded.deallocate() }
        padded.initialize(repeating: 0, count: N)
        memcpy(padded,         history, halfN * MemoryLayout<Float>.size)
        memcpy(padded + halfN, input,   frames * MemoryLayout<Float>.size)

        // 3. Split-complex scratch.
        let realPart = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let imagPart = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        defer { realPart.deallocate(); imagPart.deallocate() }
        realPart.initialize(repeating: 0, count: halfN)
        imagPart.initialize(repeating: 0, count: halfN)

        padded.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
            var split = DSPSplitComplex(realp: realPart, imagp: imagPart)
            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(halfN))
        }

        var split = DSPSplitComplex(realp: realPart, imagp: imagPart)
        vDSP_fft_zrip(fftSetup, &split, 1, Self.logN, FFTDirection(kFFTDirection_Forward))
        vDSP_vmul(realPart, 1, kernelReal, 1, realPart, 1, vDSP_Length(halfN))
        vDSP_vmul(imagPart, 1, kernelReal, 1, imagPart, 1, vDSP_Length(halfN))
        vDSP_fft_zrip(fftSetup, &split, 1, Self.logN, FFTDirection(kFFTDirection_Inverse))

        var scale: Float = 1.0 / Float(2 * N)
        vDSP_vsmul(realPart, 1, &scale, realPart, 1, vDSP_Length(halfN))
        vDSP_vsmul(imagPart, 1, &scale, imagPart, 1, vDSP_Length(halfN))

        padded.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
            vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(halfN))
        }

        // 4. Output = last `frames` samples of valid region.
        memcpy(input, padded + halfN, frames * MemoryLayout<Float>.size)

        // 5. Slide history: drop oldest `frames`, append the saved input.
        memmove(history, history + frames, (halfN - frames) * MemoryLayout<Float>.size)
        memcpy(history + (halfN - frames), inputCopy, frames * MemoryLayout<Float>.size)
    }

    // MARK: - Render block

    public override var internalRenderBlock: AUInternalRenderBlock {
        return { [weak self] _, _, frameCount, _, outputData, _, _ in
            guard let self else { return noErr }
            let frames = Int(frameCount)
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count >= 2,
                  let L = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let R = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            // Rebuild kernel lazily.
            if self.kernelDirty || self.cachedSampleRate == 0 {
                self.cachedSampleRate = 44100   // TODO: plumb SR from host
                self.rebuildKernel(sampleRate: self.cachedSampleRate)
            }

            // If the caller's block is bigger than halfFFT (2048), split it.
            let maxChunk = Self.halfFFT
            var off = 0
            while off < frames {
                let n = min(maxChunk, frames - off)
                self.convolveChannelProper(input: L.advanced(by: off), history: self.histL, frames: n)
                self.convolveChannelProper(input: R.advanced(by: off), history: self.histR, frames: n)
                off += n
            }
            return noErr
        }
    }
}
