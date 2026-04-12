/*
 *  PROJECT ToooT (ToooT_Core)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 */

import Foundation
import Accelerate

// MARK: - Supporting types

public enum LoopType: UInt8, Sendable, BitwiseCopyable {
    case none = 0xFF, classic = 0, pingPong = 1
}

public enum SynthMode: Int, Sendable {
    case sampler, wavetable, granular
}

public struct EnvelopePoint: Sendable {
    public let pos: Int16
    public let val: Int16
    public init(pos: Int16, val: Int16) { self.pos = pos; self.val = val }
}

public struct FixedEnvelope: Sendable {
    public static let maxPoints = 32
    private var points: (
        EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint,
        EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint,
        EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint,
        EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint, EnvelopePoint
    )
    public var count: Int = 0

    public static let empty = FixedEnvelope()

    public init() {
        let z = EnvelopePoint(pos: 0, val: 0)
        points = (
            z,z,z,z,z,z,z,z,
            z,z,z,z,z,z,z,z,
            z,z,z,z,z,z,z,z,
            z,z,z,z,z,z,z,z
        )
    }

    public init(_ array: [EnvelopePoint]) {
        self.init()
        self.count = min(array.count, Self.maxPoints)
        withUnsafeMutablePointer(to: &self.points) { tuplePtr in
            let buffer = UnsafeMutableRawPointer(tuplePtr).bindMemory(to: EnvelopePoint.self, capacity: Self.maxPoints)
            for i in 0..<self.count {
                buffer[i] = array[i]
            }
        }
    }

    public var isEmpty: Bool { count == 0 }

    @inline(__always)
    public func withUnsafeBuffer<R>(_ body: (UnsafeBufferPointer<EnvelopePoint>) -> R) -> R {
        withUnsafePointer(to: points) { tuplePtr in
            let buffer = UnsafeRawPointer(tuplePtr).bindMemory(to: EnvelopePoint.self, capacity: count)
            return body(UnsafeBufferPointer(start: buffer, count: count))
        }
    }
}

// MARK: - SynthVoice

public struct SynthVoice {
    public var active:            Bool  = false
    public var frequency:         Float = 440.0
    public var targetFrequency:   Float = 440.0
    public var velocity:          Float = 0.0
    public var currentPanning:    Float = 0.5
    public var sampleOffset:      Int   = 0
    public var sampleLength:      Int   = 0
    public var isStereo:          Bool  = false
    public var loopType:          LoopType = .none
    public var loopStart:         Int   = 0
    public var loopLength:        Int   = 0
    
    public var synthMode:         SynthMode = .sampler
    public var grainSize:         Float = 0.05
    public var wavetableIndex:    Float = 0.0
    
    public var volumeEnvelope:    FixedEnvelope = .empty
    public var panningEnvelope:   FixedEnvelope = .empty
    public var pitchEnvelope:     FixedEnvelope = .empty
    public var envPosition:       Int   = 0
    
    public var currentEffect:     UInt8 = 0
    public var currentEffectParam: UInt8 = 0
    public var vibratoPos:        Int   = 0
    public var tremoloPos:        Int   = 0
    
    private var currentPhase:     Float = 0.0
    private var smoothedGain:     Float = 0.0
    private var smoothedPanL:     Float = 0.5
    private var smoothedPanR:     Float = 0.5
    public var originalFrequency: Float = 0.0
    private var loopDirection:    Float = 1.0

    public init() {}

    public mutating func trigger(
        frequency:       Float,
        velocity:        Float,
        offset:          Int,
        length:          Int,
        isStereo:        Bool          = false,
        loopType:        LoopType      = .none,
        loopStart:       Int           = 0,
        loopLength:      Int           = 0,
        volumeEnvelope:  FixedEnvelope = .empty,
        panningEnvelope: FixedEnvelope = .empty,
        pitchEnvelope:   FixedEnvelope = .empty,
        volumeEnvOn:     Bool          = false,
        panningEnvOn:    Bool          = false,
        pitchEnvOn:      Bool          = false,
        finetune:        Int8          = 0,
        defaultPan:      Float         = 0.5
    ) {
        // Apply MOD finetune: each unit = 1/8 semitone = pow(2, 1/96).
        // Skip the exp call entirely when finetune is zero (the common case).
        let tunedFreq          = finetune != 0 ? frequency * powf(2.0, Float(finetune) / 96.0) : frequency
        self.frequency         = tunedFreq
        self.originalFrequency = tunedFreq
        self.targetFrequency   = tunedFreq
        self.velocity          = velocity
        self.sampleOffset      = offset
        self.sampleLength      = length
        self.isStereo          = isStereo
        self.loopType          = loopType
        self.loopStart         = loopStart
        self.loopLength        = loopLength

        self.volumeEnvelope    = volumeEnvOn ? volumeEnvelope : .empty
        self.panningEnvelope   = panningEnvOn ? panningEnvelope : .empty
        self.pitchEnvelope     = pitchEnvOn ? pitchEnvelope : .empty

        self.currentPanning    = defaultPan
        self.currentPhase      = 0.0
        self.loopDirection     = 1.0
        self.envPosition       = 0
        self.vibratoPos        = 0
        self.tremoloPos        = 0
        self.active            = length > 0
        
        let envVal = calculateEnvelopeValue(env: self.volumeEnvelope)
        self.smoothedGain      = velocity * envVal
        self.smoothedPanR      = defaultPan
        self.smoothedPanL      = 1.0 - defaultPan
    }

    public mutating func processTickEffects(tick: Int) {
        let param = currentEffectParam
        let x = (param & 0xF0) >> 4
        let y =  param & 0x0F

        switch currentEffect {
        case 0x00: // Arpeggio
            if param != 0 {
                var semitones = 0
                if      tick % 3 == 1 { semitones = Int(x) }
                else if tick % 3 == 2 { semitones = Int(y) }
                frequency = originalFrequency * pow(2.0, Float(semitones) / 12.0)
            }
        case 0x01: // Portamento Up
            if tick > 0 {
                let clock: Float = 3546895.0
                var period = clock / max(1.0, originalFrequency)
                period -= Float(param)
                period = max(1.0, period)
                originalFrequency = clock / period
                frequency = originalFrequency
            }
        case 0x02: // Portamento Down
            if tick > 0 {
                let clock: Float = 3546895.0
                var period = clock / max(1.0, originalFrequency)
                period += Float(param)
                originalFrequency = clock / period
                frequency = originalFrequency
            }
        case 0x03, 0x05: // Tone Portamento (0x05 also applies volume slide)
            if tick > 0 && targetFrequency > 0 {
                let clock: Float = 3546895.0
                let curP = clock / max(1.0, frequency)
                let tgtP = clock / max(1.0, targetFrequency)
                if abs(curP - tgtP) <= Float(param) {
                    frequency = targetFrequency
                    originalFrequency = targetFrequency
                } else if curP > tgtP {
                    let newP = curP - Float(param)
                    frequency = clock / newP; originalFrequency = frequency
                } else {
                    let newP = curP + Float(param)
                    frequency = clock / newP; originalFrequency = frequency
                }
                if currentEffect == 0x05 {
                    if x > 0 { velocity = min(1.0, velocity + Float(x) / 64.0) }
                    else if y > 0 { velocity = max(0.0, velocity - Float(y) / 64.0) }
                }
            }
        case 0x04, 0x06: // Vibrato (0x06 also applies volume slide)
            let sinVal = sinf(Float(vibratoPos & 63) * 2.0 * .pi / 64.0)
            frequency = originalFrequency * (1.0 + sinVal * Float(y) / 128.0)
            vibratoPos = (vibratoPos + Int(x)) & 63
            if currentEffect == 0x06 {
                if tick > 0 {
                    if x > 0 { velocity = min(1.0, velocity + Float(x) / 64.0) }
                    else if y > 0 { velocity = max(0.0, velocity - Float(y) / 64.0) }
                }
            }
        case 0x07: // Tremolo
            tremoloPos = (tremoloPos + Int(x)) & 63
        case 0x08: // Set Panning (0x00=left, 0x80=center, 0xFF=right)
            currentPanning = Float(param) / 255.0
        case 0x0A: // Volume Slide
            if tick > 0 {
                if x > 0 { velocity = min(1.0, velocity + Float(x) / 64.0) }
                else if y > 0 { velocity = max(0.0, velocity - Float(y) / 64.0) }
            }
        default: break
        }
    }

    /// Sets the sample playback start position (effect 9xx — Sample Offset).
    /// Must be called after trigger().
    public mutating func setSampleOffset(_ offset: Int) {
        guard active, offset < sampleLength else { return }
        currentPhase = Float(offset)
    }

    @inline(__always)
    public mutating func process(
        bufferL:          UnsafeMutablePointer<Float>,
        bufferR:          UnsafeMutablePointer<Float>,
        scratchBuffer:    UnsafeMutablePointer<Float>,
        monoBuffer:       UnsafeMutablePointer<Float>? = nil,
        positionsScratch: UnsafeMutablePointer<Float>,
        sampleBank:       UnifiedSampleBank,
        count:            Int,
        sampleRate:       Float
    ) {
        guard active else { return }

        let envVal = calculateEnvelopeValue(env: volumeEnvelope)
        
        // Tremolo modulation
        var tremoloMod: Float = 0.0
        if currentEffect == 0x07 {
            let y = currentEffectParam & 0x0F
            let sinVal = sinf(Float(tremoloPos & 63) * 2.0 * .pi / 64.0)
            tremoloMod = sinVal * Float(y) / 64.0
        }
        
        let targetGain = (velocity + tremoloMod).clamped(to: 0...1.0) * envVal

        let panVal = calculateEnvelopeValue(env: panningEnvelope)
        if !panningEnvelope.isEmpty { currentPanning = panVal }
        let targetPanR = currentPanning, targetPanL = 1.0 - targetPanR

        let pitchVal = calculateEnvelopeValue(env: pitchEnvelope)
        let pitchMod: Float = pitchEnvelope.isEmpty ? 1.0 : pow(2.0, (pitchVal - 0.5) * 2.0)
        let currentFreq = frequency * pitchMod

        let stepBase = (currentFreq / sampleRate)
        let startPtr = sampleBank.samplePointer.advanced(by: sampleOffset)
        let lStart = loopStart, lLen = loopLength, lEnd = lStart + lLen
        let isLooping = loopType != .none && loopLength > 2

        var activeCount = 0

        let grainSamples = max(1.0, grainSize * sampleRate)
        let wtOffset = wavetableIndex * Float(max(0, sampleLength - 2048))

        // Fast path: non-looping, forward sampler. Compute activeCount analytically and
        // fill positionsScratch with vDSP_vramp — eliminates the scalar position loop.
        let useFastPath = synthMode == .sampler && !isLooping && stepBase > 0
        if useFastPath {
            let remaining = max(0.0, Float(sampleLength - 1) - currentPhase)
            activeCount = max(0, min(count, Int(remaining / stepBase)))
            if activeCount < count { active = false }
            if activeCount > 0 {
                var rampStart = currentPhase, rampStep = stepBase
                vDSP_vramp(&rampStart, &rampStep, positionsScratch, 1, vDSP_Length(activeCount))
                currentPhase += Float(activeCount) * stepBase
            }
        } else {
            // Slow path: looping, ping-pong, reverse, granular, wavetable — keep scalar loop.
            for _ in 0..<count {
                // Recompute step each sample for ping-pong (direction may flip)
                let step = stepBase * loopDirection

                if synthMode == .granular {
                    let startPhase = Float(sampleOffset) + wtOffset
                    if currentPhase < startPhase || currentPhase > startPhase + grainSamples {
                        currentPhase = startPhase
                    }
                } else if synthMode == .wavetable {
                    let startPhase = Float(sampleOffset) + wtOffset
                    let tableLen = Float(loopLength > 2 ? loopLength : 2048)
                    if currentPhase < startPhase || currentPhase > startPhase + tableLen {
                        currentPhase = startPhase
                    }
                } else if isLooping {
                    if loopType == .pingPong {
                        if loopDirection > 0 && currentPhase >= Float(lEnd) {
                            loopDirection = -1.0; currentPhase = Float(lEnd) - (currentPhase - Float(lEnd))
                        } else if loopDirection < 0 && currentPhase <= Float(lStart) {
                            loopDirection = 1.0; currentPhase = Float(lStart) + (Float(lStart) - currentPhase)
                        }
                    } else {
                        while currentPhase >= Float(lEnd) { currentPhase -= Float(lLen) }
                        while currentPhase < Float(lStart) { currentPhase += Float(lLen) }
                    }
                }

                let idx = Int(currentPhase)
                if !isLooping && synthMode == .sampler && (idx < 0 || idx >= sampleLength - 1) { active = false; break }
                // For looping samples, the loop wrapping above keeps phase in bounds.
                // Only kill the voice if something went catastrophically wrong (safety net).
                if !isLooping && (idx < 0 || idx >= sampleLength - 1) { active = false; break }
                // Safety clamp for looping (should not normally trigger)
                if isLooping && (idx < 0 || idx >= sampleLength) { active = false; break }

                positionsScratch[activeCount] = currentPhase
                activeCount += 1
                currentPhase += step
            }
        }

        guard activeCount > 0 else { return }

        var curGainL = smoothedGain * smoothedPanL
        let stepGainL = (targetGain * targetPanL - curGainL) / Float(count)
        var curGainR = smoothedGain * smoothedPanR
        let stepGainR = (targetGain * targetPanR - curGainR) / Float(count)
        var curMono = smoothedGain
        let stepMono = (targetGain - curMono) / Float(count)

        if !isStereo {
            if useFastPath {
                // Vectorized linear interpolation via vDSP_vlint (L32: cap positions to
                // [0, sampleLength-2] so the +1 read is always in bounds).
                var minPos: Float = 0, maxPos = Float(sampleLength - 2)
                vDSP_vclip(positionsScratch, 1, &minPos, &maxPos,
                           positionsScratch, 1, vDSP_Length(activeCount))
                vDSP_vlint(startPtr, positionsScratch, 1,
                           scratchBuffer, 1,
                           vDSP_Length(activeCount), vDSP_Length(sampleLength))
            } else {
                // Scalar 4-point Hermite — required for looping/ping-pong so indices can
                // be wrapped correctly around the loop boundary.
                for i in 0..<activeCount {
                    let phase = positionsScratch[i]
                    let idx = Int(phase)
                    let f = phase - Float(idx)

                    let i0: Int, i1: Int, i2: Int, i3: Int
                    if isLooping && lLen > 2 {
                        i1 = idx
                        i0 = idx - 1 < lStart ? lEnd - 1 : idx - 1
                        i2 = idx + 1 >= lEnd ? lStart : idx + 1
                        i3 = idx + 2 >= lEnd ? lStart + ((idx + 2 - lEnd) % max(1, lLen)) : idx + 2
                    } else {
                        i0 = max(0, idx - 1)
                        i1 = idx
                        i2 = min(sampleLength - 1, idx + 1)
                        i3 = min(sampleLength - 1, idx + 2)
                    }

                    scratchBuffer[i] = hermite(startPtr[i0], startPtr[i1], startPtr[i2], startPtr[i3], f)
                }
            }

            // Vectorized gain-ramp apply: bufferX[i] += scratch[i] * (startGain + i * stepGain)
            // positionsScratch is free after the phase-generation loop — reuse as gain ramp temp.
            var rampStartL = curGainL, rampStepL = stepGainL
            vDSP_vramp(&rampStartL, &rampStepL, positionsScratch, 1, vDSP_Length(activeCount))
            vDSP_vma(scratchBuffer, 1, positionsScratch, 1, bufferL, 1, bufferL, 1, vDSP_Length(activeCount))

            var rampStartR = curGainR, rampStepR = stepGainR
            vDSP_vramp(&rampStartR, &rampStepR, positionsScratch, 1, vDSP_Length(activeCount))
            vDSP_vma(scratchBuffer, 1, positionsScratch, 1, bufferR, 1, bufferR, 1, vDSP_Length(activeCount))

            if let mono = monoBuffer {
                var rampStartM = curMono, rampStepM = stepMono
                vDSP_vramp(&rampStartM, &rampStepM, positionsScratch, 1, vDSP_Length(activeCount))
                vDSP_vma(scratchBuffer, 1, positionsScratch, 1, mono, 1, mono, 1, vDSP_Length(activeCount))
            }
        } else {
            let frameCount = sampleLength / 2  // interleaved stereo: 2 floats per frame
            let maxFrame = max(0, frameCount - 2) // leave room for hermite +1
            for i in 0..<activeCount {
                let phase = positionsScratch[i]
                let idx = Int(phase)
                let f = phase - Float(idx)
                
                let i0 = max(0, idx - 1)
                let i1 = idx
                let i2 = min(maxFrame, idx + 1)
                let i3 = min(maxFrame, idx + 2)
                
                let sL = hermite(startPtr[i0 * 2], startPtr[i1 * 2], startPtr[i2 * 2], startPtr[i3 * 2], f)
                let sR = hermite(startPtr[i0 * 2 + 1], startPtr[i1 * 2 + 1], startPtr[i2 * 2 + 1], startPtr[i3 * 2 + 1], f)
                
                bufferL[i] += sL * curGainL
                bufferR[i] += sR * curGainR
                monoBuffer?[i] += (sL + sR) * 0.5 * curMono
                
                curGainL += stepGainL
                curGainR += stepGainR
                curMono += stepMono
            }
        }

        smoothedGain = targetGain
        smoothedPanL = targetPanL
        smoothedPanR = targetPanR
        envPosition += count
    }

    @inline(__always)
    private func hermite(_ y0: Float, _ y1: Float, _ y2: Float, _ y3: Float, _ f: Float) -> Float {
        let c0 = y1, c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * f + c2) * f + c1) * f + c0
    }

    @inline(__always)
    private func calculateEnvelopeValue(env: FixedEnvelope) -> Float {
        guard !env.isEmpty else { return 1.0 }
        return env.withUnsafeBuffer { pts in
            let tick = Int16(envPosition / 441)
            let last = pts[pts.count - 1]
            if tick >= last.pos { return Float(last.val) / 64.0 }
            var p1 = pts[0], p2 = pts[0]
            for i in 0..<pts.count - 1 {
                if tick >= pts[i].pos && tick < pts[i + 1].pos {
                    p1 = pts[i]; p2 = pts[i + 1]; break
                }
            }
            if p1.pos == p2.pos { return Float(p1.val) / 64.0 }
            let frac = Float(tick - p1.pos) / Float(max(1, p2.pos - p1.pos))
            return (Float(p1.val) + Float(p2.val - p1.val) * frac) / 64.0
        }
    }
}
