/*
 *  PROJECT ToooT (ToooT_Plugins)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  GPU-Accelerated & Accelerate Sample Modifiers.
 */

import Foundation
import Metal
import Accelerate
import ToooT_Core

public enum GPU_DSP {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let commandQueue = device?.makeCommandQueue()

    /// Metal shader library. Contains every compute kernel this module exposes.
    /// Keep kernels small and single-purpose — each is dispatched as a flat 1D grid.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void normalize_samples(
        device float* samples [[buffer(0)]],
        device float* maxVal  [[buffer(1)]],
        uint id [[thread_position_in_grid]]
    ) {
        samples[id] = samples[id] / (*maxVal);
    }

    // In-place sample gain (scalar × vector).
    kernel void gain_samples(
        device float* samples [[buffer(0)]],
        device float* gain    [[buffer(1)]],
        uint id [[thread_position_in_grid]]
    ) {
        samples[id] = samples[id] * (*gain);
    }

    // Pointwise multiply — used in FFT-convolution kernels (magnitude shaping).
    kernel void pointwise_multiply(
        device float* a [[buffer(0)]],
        device float* b [[buffer(1)]],
        device float* out [[buffer(2)]],
        uint id [[thread_position_in_grid]]
    ) {
        out[id] = a[id] * b[id];
    }

    // Direct-form FIR convolution for short kernels (N ≤ 64).
    // For longer kernels use OfflineDSP.resample (CPU FFT) or an explicit CPU-FFT path.
    kernel void fir_convolve(
        device const float* input  [[buffer(0)]],
        device const float* kernel [[buffer(1)]],
        device float*       output [[buffer(2)]],
        constant uint&      kernelLen [[buffer(3)]],
        uint id [[thread_position_in_grid]]
    ) {
        float acc = 0;
        for (uint k = 0; k < kernelLen; k++) {
            if (id >= k) acc += input[id - k] * kernel[k];
        }
        output[id] = acc;
    }

    // Simple softclip (tanh approximation) — saturating limiter used by offline
    // loudness-normalize fallback and bounce-export chains.
    kernel void softclip(
        device float* samples [[buffer(0)]],
        uint id [[thread_position_in_grid]]
    ) {
        float x = samples[id];
        samples[id] = tanh(x);
    }
    """

    // Pipeline cache — one MTLComputePipelineState per kernel.
    private static let library: MTLLibrary? = device.flatMap {
        try? $0.makeLibrary(source: shaderSource, options: nil)
    }
    private static func pipeline(for function: String) -> MTLComputePipelineState? {
        guard let device = device,
              let fn = library?.makeFunction(name: function) else { return nil }
        return try? device.makeComputePipelineState(function: fn)
    }

    private static let normalizePipeline: MTLComputePipelineState?  = pipeline(for: "normalize_samples")
    private static let gainPipeline:      MTLComputePipelineState?  = pipeline(for: "gain_samples")
    private static let mulPipeline:       MTLComputePipelineState?  = pipeline(for: "pointwise_multiply")
    private static let firPipeline:       MTLComputePipelineState?  = pipeline(for: "fir_convolve")
    private static let softclipPipeline:  MTLComputePipelineState?  = pipeline(for: "softclip")

    /// True when Metal is available and all kernels compiled cleanly.
    public static var isAvailable: Bool {
        return device != nil && commandQueue != nil && normalizePipeline != nil
            && gainPipeline != nil && mulPipeline != nil && firPipeline != nil
            && softclipPipeline != nil
    }

    public static func normalizeGPU(bank: UnifiedSampleBank, offset: Int, length: Int) {
        guard let device = device, let queue = commandQueue, let pipeline = normalizePipeline else { return }
        let ptr = bank.samplePointer.advanced(by: offset)
        var maxVal: Float = 0
        vDSP_maxmgv(ptr, 1, &maxVal, vDSP_Length(length))
        guard maxVal > 0, let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        guard let buffer = device.makeBuffer(bytesNoCopy: ptr, length: length * 4, options: .storageModeShared, deallocator: nil) else { return }
        enc.setComputePipelineState(pipeline); enc.setBuffer(buffer, offset: 0, index: 0)
        var m = maxVal; enc.setBytes(&m, length: 4, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: (length + 255) / 256, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    }

    /// In-place gain. Only worth doing on-GPU when `length` > ~100 k; vDSP_vsmul is
    /// faster for smaller ranges due to dispatch overhead.
    public static func gainGPU(bank: UnifiedSampleBank, offset: Int, length: Int, gain: Float) {
        guard let device = device, let queue = commandQueue, let pipeline = gainPipeline else { return }
        let ptr = bank.samplePointer.advanced(by: offset)
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder(),
              let buffer = device.makeBuffer(bytesNoCopy: ptr, length: length * 4,
                                             options: .storageModeShared, deallocator: nil)
        else { return }
        enc.setComputePipelineState(pipeline); enc.setBuffer(buffer, offset: 0, index: 0)
        var g = gain; enc.setBytes(&g, length: 4, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: (length + 255) / 256, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    }

    /// Short-kernel FIR convolution. Use only for kernel length ≤ 64 — beyond that
    /// the quadratic inner loop makes a CPU FFT-convolution path faster.
    /// Output is written back over `input` (in-place semantics like OfflineDSP peers).
    public static func firConvolveGPU(bank: UnifiedSampleBank, offset: Int, length: Int,
                                      kernel: [Float]) {
        guard let device = device, let queue = commandQueue, let pipeline = firPipeline,
              kernel.count <= 64 else { return }
        let src = bank.samplePointer.advanced(by: offset)
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder(),
              let inBuf = device.makeBuffer(bytesNoCopy: src, length: length * 4,
                                            options: .storageModeShared, deallocator: nil),
              let outBuf = device.makeBuffer(length: length * 4,
                                             options: .storageModeShared),
              let kBuf = device.makeBuffer(bytes: kernel, length: kernel.count * 4,
                                           options: .storageModeShared)
        else { return }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(inBuf,  offset: 0, index: 0)
        enc.setBuffer(kBuf,   offset: 0, index: 1)
        enc.setBuffer(outBuf, offset: 0, index: 2)
        var kLen = UInt32(kernel.count)
        enc.setBytes(&kLen, length: 4, index: 3)
        enc.dispatchThreadgroups(MTLSize(width: (length + 255) / 256, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        // Copy output back.
        memcpy(src, outBuf.contents(), length * 4)
    }

    /// Vectorized softclip (tanh) — batched saturation.
    public static func softclipGPU(bank: UnifiedSampleBank, offset: Int, length: Int) {
        guard let device = device, let queue = commandQueue, let pipeline = softclipPipeline else { return }
        let ptr = bank.samplePointer.advanced(by: offset)
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder(),
              let buffer = device.makeBuffer(bytesNoCopy: ptr, length: length * 4,
                                             options: .storageModeShared, deallocator: nil)
        else { return }
        enc.setComputePipelineState(pipeline); enc.setBuffer(buffer, offset: 0, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: (length + 255) / 256, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    }
}

public enum OfflineDSP {
    public enum WaveType: Int, CaseIterable, Identifiable {
        case sine, square, saw, triangle, noise
        public var id: Int { self.rawValue }
    }

    private static func getSampleBuffer(bank: UnifiedSampleBank, offset: Int, length: Int) -> (UnsafeMutablePointer<Float>, Int)? {
        guard offset + length <= bank.totalSamples else { return nil }
        return (bank.samplePointer.advanced(by: offset), length)
    }

    public static func amplitude(bank: UnifiedSampleBank, offset: Int, length: Int, percentage: Float) {
        guard let (ptr, count) = getSampleBuffer(bank: bank, offset: offset, length: length) else { return }
        var factor = percentage / 100.0
        vDSP_vsmul(ptr, 1, &factor, ptr, 1, vDSP_Length(count))
    }

    public static func separateStems(bank: UnifiedSampleBank, offset: Int, length: Int) {
        guard let (ptr, count) = getSampleBuffer(bank: bank, offset: offset, length: length) else { return }
        let lowOffset = offset + length
        let midOffset = offset + length * 2
        let highOffset = offset + length * 3
        
        var temp = [Float](repeating: 0, count: count)
        temp.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress {
                memcpy(base, ptr, count * 4)
            }
        }
        
        bank.overwriteRegion(offset: lowOffset, data: temp)
        bank.overwriteRegion(offset: midOffset, data: temp)
        bank.overwriteRegion(offset: highOffset, data: temp)
    }

    public static func generateHarmonicSample(bank: UnifiedSampleBank, offset: Int, length: Int, baseFreq: Float) {
        let ptr = bank.samplePointer.advanced(by: offset)
        let n = vDSP_Length(length)
        vDSP_vclr(ptr, 1, n)
        
        for harm in 1...5 {
            let freq = baseFreq * Float(harm)
            let amp = 1.0 / Float(harm)
            var phaseStart: Float = 0.0
            var phaseStep: Float = 2.0 * .pi * freq / 44100.0
            var temp = [Float](repeating: 0, count: length)
            vDSP_vramp(&phaseStart, &phaseStep, &temp, 1, n)
            var len = Int32(length)
            temp.withUnsafeMutableBufferPointer { t in
                vvsinf(t.baseAddress!, t.baseAddress!, &len)
            }
            var a = amp
            vDSP_vsma(&temp, 1, &a, ptr, 1, ptr, 1, n)
        }
        
        var maxVal: Float = 0
        vDSP_maxv(ptr, 1, &maxVal, n)
        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(ptr, 1, &scale, ptr, 1, n)
        }
    }

    public static func normalize(bank: UnifiedSampleBank, offset: Int, length: Int) {
        GPU_DSP.normalizeGPU(bank: bank, offset: offset, length: length)
    }

    public static func invert(bank: UnifiedSampleBank, offset: Int, length: Int) {
        guard let (ptr, count) = getSampleBuffer(bank: bank, offset: offset, length: length) else { return }
        vDSP_vneg(ptr, 1, ptr, 1, vDSP_Length(count))
    }

    public static func silence(bank: UnifiedSampleBank, offset: Int, length: Int) {
        guard let (ptr, count) = getSampleBuffer(bank: bank, offset: offset, length: length) else { return }
        vDSP_vclr(ptr, 1, vDSP_Length(count))
    }

    public static func backwards(bank: UnifiedSampleBank, offset: Int, length: Int) {
        guard let (ptr, count) = getSampleBuffer(bank: bank, offset: offset, length: length) else { return }
        // vDSP_vrvrs reverses a vector in-place — single SIMD pass, no temp allocation.
        vDSP_vrvrs(ptr, 1, vDSP_Length(count))
    }

    public static func fade(bank: UnifiedSampleBank, offset: Int, length: Int, isFadeIn: Bool) {
        guard let (ptr, count) = getSampleBuffer(bank: bank, offset: offset, length: length) else { return }
        // Generate the gain ramp (0→1 or 1→0), then multiply in-place.
        var rampStart: Float = isFadeIn ? 0.0 : 1.0
        var rampStep:  Float = (isFadeIn ? 1.0 : -1.0) / Float(max(1, count - 1))
        var ramp = [Float](repeating: 0, count: count)
        vDSP_vramp(&rampStart, &rampStep, &ramp, 1, vDSP_Length(count))
        vDSP_vmul(ptr, 1, &ramp, 1, ptr, 1, vDSP_Length(count))
    }

    public static func echo(bank: UnifiedSampleBank, offset: Int, length: Int, delaySamples: Int, feedback: Float) {
        guard let (ptr, count) = getSampleBuffer(bank: bank, offset: offset, length: length), delaySamples < count else { return }
        for i in delaySamples..<count { ptr[i] += ptr[i - delaySamples] * feedback }
    }

    public static func smooth(bank: UnifiedSampleBank, offset: Int, length: Int) {
        guard let (ptr, count) = getSampleBuffer(bank: bank, offset: offset, length: length) else { return }
        var filter: [Float] = [0.2, 0.2, 0.2, 0.2, 0.2]
        var temp = [Float](repeating: 0, count: count)
        vDSP_conv(ptr, 1, &filter, 1, &temp, 1, vDSP_Length(count), vDSP_Length(filter.count))
        _ = temp.withUnsafeBufferPointer { buf in memcpy(ptr, buf.baseAddress!, count * MemoryLayout<Float>.size) }
    }

    public static func depth(bank: UnifiedSampleBank, offset: Int, length: Int, bits: Int) {
        guard let (ptr, count) = getSampleBuffer(bank: bank, offset: offset, length: length) else { return }
        // Bit-crush: quantise to 2^bits levels using three vDSP passes.
        var levels    = pow(2.0, Float(bits))
        var invLevels = 1.0 / levels
        vDSP_vsmul(ptr, 1, &levels, ptr, 1, vDSP_Length(count))    // scale up
        var iLen = Int32(count); vvnintf(ptr, ptr, &iLen)           // nearest-integer round
        vDSP_vsmul(ptr, 1, &invLevels, ptr, 1, vDSP_Length(count)) // scale back
    }

    public static func crop(bank: UnifiedSampleBank, offset: Int, length: Int, startPercent: Float, endPercent: Float) -> Int {
        let safeStart = startPercent.clamped(to: 0...100)
        let safeEnd   = endPercent.clamped(to: 0...100)
        guard safeStart < safeEnd else { return length }   // Invalid range: no-op
        guard let (ptr, count) = getSampleBuffer(bank: bank, offset: offset, length: length) else { return length }
        let start = Int(Float(count) * (safeStart / 100.0))
        let end   = min(count, Int(Float(count) * (safeEnd / 100.0)))
        let newLen = end - start
        guard newLen > 0 else { return length }
        var temp = [Float](repeating: 0, count: newLen)
        memcpy(&temp, ptr.advanced(by: start), newLen * MemoryLayout<Float>.size)
        vDSP_vclr(ptr, 1, vDSP_Length(count))
        bank.overwriteRegion(offset: offset, data: temp)
        return newLen
    }

    public static func crossfade(bank: UnifiedSampleBank, offset: Int, length: Int, loopStart: Int, loopLength: Int) {
        guard let (ptr, _) = getSampleBuffer(bank: bank, offset: offset, length: length), loopLength > 100 else { return }
        let fadeLen = min(loopLength / 2, 1000)
        for i in 0..<fadeLen {
            let alpha = Float(i) / Float(fadeLen)
            ptr[loopStart + i] = (ptr[loopStart + i] * alpha) + (ptr[loopStart + loopLength - fadeLen + i] * (1.0 - alpha))
        }
    }

    public static func mix(bank: UnifiedSampleBank, offset1: Int, offset2: Int, length: Int, mixRatio: Float) {
        guard let (ptr1, count1) = getSampleBuffer(bank: bank, offset: offset1, length: length),
              let (ptr2, _) = getSampleBuffer(bank: bank, offset: offset2, length: length) else { return }
        var r1 = 1.0 - mixRatio, r2 = mixRatio
        vDSP_vsmsma(ptr1, 1, &r1, ptr2, 1, &r2, ptr1, 1, vDSP_Length(count1))
    }

    public static func resample(bank: UnifiedSampleBank, offset: Int, length: Int, factor: Float) -> Int {
        guard factor > 0, let (ptr, count) = getSampleBuffer(bank: bank, offset: offset, length: length) else { return length }
        // vDSP_vlint requires all indices to be in [0, count-2].
        // With ramp = i * factor, the last index is (newCount-1) * factor.
        // We cap newCount so the last index stays ≤ count - 2.
        let maxNewCount = count > 1 ? Int(Float(count - 1) / factor) : 1
        let newCount = max(1, min(maxNewCount, Int(Float(count) / factor)))
        // Build a floating-point index ramp, then interpolate the source in one SIMD call.
        var rampStart: Float = 0.0
        var rampStep:  Float = factor
        var indices = [Float](repeating: 0, count: newCount)
        vDSP_vramp(&rampStart, &rampStep, &indices, 1, vDSP_Length(newCount))
        var temp = [Float](repeating: 0, count: newCount)
        vDSP_vlint(ptr, &indices, 1, &temp, 1, vDSP_Length(newCount), vDSP_Length(count))
        vDSP_vclr(ptr, 1, vDSP_Length(count))
        bank.overwriteRegion(offset: offset, data: temp)
        return newCount
    }

    /// SOLA (Synchronous Overlap-Add) time-stretch. Preserves pitch.
    ///
    /// `factor` is the ratio of output duration to input duration — `2.0` halves the tempo,
    /// `0.5` doubles it. Returns the new sample count (≤ input × factor).
    ///
    /// Implementation notes:
    ///   • Overlap between output windows is a half-window crossfade (a cosine or linear ramp).
    ///   • Seam alignment: within a small search window we pick the offset that maximises the
    ///     dot product between the source segment and the decaying tail of the output buffer
    ///     (vDSP_dotpr). That keeps waveform periodicity aligned across the seam so the output
    ///     is transient-coherent rather than phasey.
    ///   • Heap use is bounded to a single temp Float array sized by the output length.
    public static func timeStretch(bank: UnifiedSampleBank,
                                   offset: Int,
                                   length: Int,
                                   factor: Float) -> Int {
        guard factor > 0.01 && factor < 100 else { return length }
        guard abs(factor - 1.0) > 0.001 else { return length }
        guard let (src, count) = getSampleBuffer(bank: bank, offset: offset, length: length),
              count > 2048 else { return length }

        let windowSize = 1024
        let overlap    = 256
        let maxSearch  = 128
        let hopOut     = windowSize - overlap
        let hopIn      = Int(Float(hopOut) / factor)

        let newCount = Int(Float(count) * factor)
        var output   = [Float](repeating: 0, count: newCount + windowSize)

        // Seed with the first window verbatim.
        let firstCopy = min(windowSize, count)
        _ = output.withUnsafeMutableBufferPointer { buf in
            memcpy(buf.baseAddress!, src, firstCopy * MemoryLayout<Float>.size)
        }

        var srcPos = hopIn
        var dstPos = hopOut

        output.withUnsafeMutableBufferPointer { outBuf in
            let outPtr = outBuf.baseAddress!
            while srcPos + windowSize + maxSearch < count && dstPos + windowSize < newCount {
                // Autocorrelation search for the best seam offset within [0, maxSearch).
                var bestOffset = 0
                var bestCorr: Float = -Float.infinity
                for k in 0..<maxSearch {
                    var corr: Float = 0
                    vDSP_dotpr(src.advanced(by: srcPos + k), 1,
                               outPtr.advanced(by: dstPos), 1,
                               &corr, vDSP_Length(overlap))
                    if corr > bestCorr { bestCorr = corr; bestOffset = k }
                }
                let seamSrc = srcPos + bestOffset

                // Linear crossfade across the overlap.
                for i in 0..<overlap {
                    let alpha = Float(i) / Float(overlap)
                    outPtr[dstPos + i] = outPtr[dstPos + i] * (1.0 - alpha)
                                       + src[seamSrc + i] * alpha
                }
                // Copy the remainder of the window after the overlap region.
                let rest = windowSize - overlap
                memcpy(outPtr.advanced(by: dstPos + overlap),
                       src.advanced(by: seamSrc + overlap),
                       rest * MemoryLayout<Float>.size)

                srcPos += hopIn
                dstPos += hopOut
            }
        }

        let actualLen = min(newCount, dstPos + overlap)
        vDSP_vclr(src, 1, vDSP_Length(count))
        bank.overwriteRegion(offset: offset, data: Array(output.prefix(actualLen)))
        return actualLen
    }

    /// Pitch shift by `semitones` (positive = up) without changing duration.
    ///
    /// Composition: SOLA stretch by `ratio` (longer, pitch unchanged), then `resample` by `ratio`
    /// (compresses back to original length while reading the source `ratio`× faster — which IS
    /// the pitch shift). Example: +12 semi (ratio 2) → stretch to 2× length, then resample by 2
    /// → N-sample output whose every cycle is half as long as the input → one octave up.
    ///
    /// Note on sign: `resample(factor:)` does `newCount = count / factor`, so factor > 1 shrinks.
    /// Pairing the SAME `factor` on stretch + resample is what keeps the final length at `length`.
    public static func pitchShift(bank: UnifiedSampleBank,
                                  offset: Int,
                                  length: Int,
                                  semitones: Float) -> Int {
        guard abs(semitones) > 0.001 else { return length }
        let ratio = powf(2.0, semitones / 12.0)
        let stretched = timeStretch(bank: bank, offset: offset, length: length, factor: ratio)
        return resample(bank: bank, offset: offset, length: stretched, factor: ratio)
    }

    public static func generateTone(bank: UnifiedSampleBank, offset: Int, length: Int, frequency: Float, type: WaveType) {
        let ptr    = bank.samplePointer.advanced(by: offset)
        let n      = vDSP_Length(length)

        switch type {
        case .sine:
            // vDSP_vrampmul generates a phase ramp, vvsincosf computes sin/cos in batch.
            // Phase at sample i = 2π × frequency × i / sampleRate
            var phaseStart: Float = 0.0
            var phaseStep:  Float = 2.0 * .pi * frequency / 44100.0
            // vDSP_vramp: ptr[i] = phaseStart + i * phaseStep
            vDSP_vramp(&phaseStart, &phaseStep, ptr, 1, n)
            // vvsinf: ptr[i] = sinf(ptr[i])  — vectorized via libm
            var len = Int32(length)
            vvsinf(ptr, ptr, &len)

        case .square:
            // Generate sine then threshold — two SIMD passes.
            var phaseStart: Float = 0.0
            var phaseStep:  Float = 2.0 * .pi * frequency / 44100.0
            vDSP_vramp(&phaseStart, &phaseStep, ptr, 1, n)
            var len = Int32(length)
            vvsinf(ptr, ptr, &len)
            // sign(x) * 0.5: clamp to ±0.5
            // Threshold sine to ±0.5: sign(x) × 0.5 — scalar is fine; square waves are rare.
            for i in 0..<length { ptr[i] = ptr[i] >= 0 ? 0.5 : -0.5 }

        case .saw:
            // Sawtooth: 2*(t*f - floor(0.5 + t*f)) = 2*fract(t*f + 0.5) - 1
            var phaseStart: Float = 0.5 * frequency / 44100.0
            var phaseStep:  Float = frequency / 44100.0
            vDSP_vramp(&phaseStart, &phaseStep, ptr, 1, n)
            var len = Int32(length)
            vvfloorf(ptr, ptr, &len)      // floor the ramp
            // saw = 2*(original_ramp - floor) - 1: rebuild ramp and subtract
            var rampStart: Float = 0.5 * frequency / 44100.0
            var rampStep:  Float = frequency / 44100.0
            var temp = [Float](repeating: 0, count: length)
            vDSP_vramp(&rampStart, &rampStep, &temp, 1, n)
            vDSP_vsub(ptr, 1, &temp, 1, ptr, 1, n)   // fract part
            var two: Float = 2.0, negOne: Float = -1.0
            vDSP_vsmsa(ptr, 1, &two, &negOne, ptr, 1, n)

        case .triangle:
            // Triangle: 2*|2*fract(f*t+0.25) - 1| - 1
            var phaseStart: Float = 0.25 * frequency / 44100.0
            var phaseStep:  Float = frequency / 44100.0
            vDSP_vramp(&phaseStart, &phaseStep, ptr, 1, n)
            var len = Int32(length)
            vvfloorf(ptr, ptr, &len)
            var rampStart: Float = 0.25 * frequency / 44100.0
            var rampStep:  Float = frequency / 44100.0
            var temp = [Float](repeating: 0, count: length)
            vDSP_vramp(&rampStart, &rampStep, &temp, 1, n)
            vDSP_vsub(ptr, 1, &temp, 1, ptr, 1, n)
            var two: Float = 2.0, negOne: Float = -1.0
            vDSP_vsmsa(ptr, 1, &two, &negOne, ptr, 1, n)
            vDSP_vabs(ptr, 1, ptr, 1, n)
            var scale: Float = 2.0
            vDSP_vsmsa(ptr, 1, &scale, &negOne, ptr, 1, n)

        case .noise:
            // vDSP_vfill is faster than a loop; noise must remain scalar (random state).
            for i in 0..<length { ptr[i] = Float.random(in: -0.5...0.5) }
        }
    }
}
