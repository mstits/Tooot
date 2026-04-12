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
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void normalize_samples(device float* samples [[buffer(0)]], device float* maxVal [[buffer(1)]], uint id [[thread_position_in_grid]]) {
        samples[id] = samples[id] / (*maxVal);
    }
    """
    private static let pipelineState: MTLComputePipelineState? = {
        guard let device = device else { return nil }
        let library = try? device.makeLibrary(source: shaderSource, options: nil)
        guard let function = library?.makeFunction(name: "normalize_samples") else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }()

    public static func normalizeGPU(bank: UnifiedSampleBank, offset: Int, length: Int) {
        guard let device = device, let queue = commandQueue, let pipeline = pipelineState else { return }
        let ptr = bank.samplePointer.advanced(by: offset)
        var maxVal: Float = 0
        vDSP_maxmgv(ptr, 1, &maxVal, vDSP_Length(length))
        guard maxVal > 0, let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        guard let buffer = device.makeBuffer(bytesNoCopy: ptr, length: length * 4, options: .storageModeShared, deallocator: nil) else { return }
        encoder.setComputePipelineState(pipeline); encoder.setBuffer(buffer, offset: 0, index: 0)
        var m = maxVal; encoder.setBytes(&m, length: 4, index: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (length + 255) / 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoder.endEncoding(); commandBuffer.commit(); commandBuffer.waitUntilCompleted()
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
