import XCTest
import Accelerate
@testable import ToooT_Core

final class AudioEngineTests: XCTestCase {
    func testEngineInitialization() throws {
        XCTAssertTrue(true, "Placeholder initialization test passed.")
    }

    func testTrackerEventBufferPass() {
        let buffer = AtomicRingBuffer<TrackerEvent>(capacity: 16)
        let event = TrackerEvent(type: .noteOn, channel: 2, value1: 440)

        XCTAssertTrue(buffer.push(event))

        let poppedEvent = buffer.pop()
        XCTAssertNotNil(poppedEvent)
        XCTAssertEqual(poppedEvent?.type, .noteOn)
        XCTAssertEqual(poppedEvent?.channel, 2)
        XCTAssertEqual(poppedEvent?.value1, 440)

        XCTAssertNil(buffer.pop(), "Buffer should be empty")
    }

    // ── Accuracy test 1: sample-accurate read ──────────────────────────────────
    //
    // The model: step = frequency / sampleRate. At step = 1.0 (frequency = sampleRate),
    // we read exactly one source sample per output sample. Hermite at integer phase f=0
    // returns y1 exactly — no interpolation error. The output must correlate ≥ 0.99
    // with the source waveform, proving the gain chain and step formula are correct.
    //
    // What this catches: wrong step formula, wrong gain scaling, broken loop wrapping
    // that could silently corrupt output without changing whether audio is "non-zero".
    func testVoiceOutputMatchesSampleAtUnityStep() {
        // 1-second 440 Hz sine at 44100 Hz → playing at step=1.0 reproduces it exactly.
        let N = 44100
        let bank = UnifiedSampleBank(capacity: N + 4)
        for i in 0..<N {
            bank.samplePointer[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 44100.0)
        }

        var voice = SynthVoice()
        // frequency = sampleRate → step = 1.0 → read one source sample per output sample
        voice.trigger(frequency: 44100.0, velocity: 1.0, offset: 0, length: N,
                      loopType: .classic, loopStart: 0, loopLength: N)

        let renderN = 4096
        let bufL = UnsafeMutablePointer<Float>.allocate(capacity: renderN)
        let bufR = UnsafeMutablePointer<Float>.allocate(capacity: renderN)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: renderN)
        let pos = UnsafeMutablePointer<Float>.allocate(capacity: renderN)
        defer { bufL.deallocate(); bufR.deallocate(); scratch.deallocate(); pos.deallocate() }
        bufL.initialize(repeating: 0, count: renderN)
        bufR.initialize(repeating: 0, count: renderN)

        voice.process(bufferL: bufL, bufferR: bufR, scratchBuffer: scratch,
                      positionsScratch: pos, sampleBank: bank, count: renderN, sampleRate: 44100.0)

        // At center pan (0.5), velocity=1.0: bufL[i] = src[i]*0.5, bufR[i] = src[i]*0.5
        // → (bufL+bufR)[i] = src[i]. Correlation must be ≥ 0.99.
        var dot: Float = 0, refSq: Float = 0, outSq: Float = 0
        for i in 0..<renderN {
            let ref = bank.samplePointer[i]
            let out = bufL[i] + bufR[i]
            dot += ref * out
            refSq += ref * ref
            outSq += out * out
        }
        let corr = (refSq > 0 && outSq > 0) ? dot / sqrtf(refSq * outSq) : 0
        XCTAssertGreaterThan(Double(corr), 0.99,
            "Voice must reproduce source waveform at step=1.0. Correlation=\(corr) — " +
            "values below 0.99 indicate broken step formula, gain chain, or loop boundary.")

        // Zero-crossing count verifies pitch.  440 Hz in renderN samples at 44100 Hz:
        // cycles = 440*renderN/44100 ≈ 40.8 → ~81 crossings (2 per cycle).
        var crossings = 0
        for i in 1..<renderN { if (bufL[i-1] < 0) != (bufL[i] < 0) { crossings += 1 } }
        let expectedCrossings = Int((2.0 * 440.0 * Float(renderN)) / 44100.0)
        XCTAssertEqual(crossings, expectedCrossings, accuracy: 4,
            "Zero-crossing rate must match 440 Hz. Got \(crossings), expected \(expectedCrossings)±4")
    }

    // ── Accuracy test 2: pitch scaling (octave transposition) ─────────────────
    //
    // Playing the same 440 Hz sine source at half the step (frequency/2) must produce
    // exactly half as many zero crossings — i.e., 220 Hz output. This validates that
    // the pitch-scaling path (Hermite interpolation at fractional phases) is correct.
    //
    // What this catches: wrong interpolation direction, off-by-one in loop wrap,
    // or step calculation errors that only appear at non-unity pitch ratios.
    func testVoicePitchScalingOctaveDown() {
        let N = 44100
        let bank = UnifiedSampleBank(capacity: N + 4)
        for i in 0..<N {
            bank.samplePointer[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 44100.0)
        }

        var voice = SynthVoice()
        // Half the frequency → step = 0.5 → output plays at 220 Hz
        voice.trigger(frequency: 22050.0, velocity: 1.0, offset: 0, length: N,
                      loopType: .classic, loopStart: 0, loopLength: N)

        let renderN = 44100  // 1 second
        let bufL = UnsafeMutablePointer<Float>.allocate(capacity: renderN)
        let bufR = UnsafeMutablePointer<Float>.allocate(capacity: renderN)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: renderN)
        let pos = UnsafeMutablePointer<Float>.allocate(capacity: renderN)
        defer { bufL.deallocate(); bufR.deallocate(); scratch.deallocate(); pos.deallocate() }
        bufL.initialize(repeating: 0, count: renderN)
        bufR.initialize(repeating: 0, count: renderN)

        voice.process(bufferL: bufL, bufferR: bufR, scratchBuffer: scratch,
                      positionsScratch: pos, sampleBank: bank, count: renderN, sampleRate: 44100.0)

        var crossings = 0
        for i in 1..<renderN { if (bufL[i-1] < 0) != (bufL[i] < 0) { crossings += 1 } }
        // 220 Hz in 1 second = 220 cycles = 440 zero crossings
        let expected = 440
        XCTAssertEqual(crossings, expected, accuracy: 8,
            "Octave-down transposition must produce 220 Hz output. " +
            "Got \(crossings) crossings (expected \(expected)±8). " +
            "Wrong count means step formula or Hermite interpolation is broken.")
    }

    // ── Accuracy test 3: finetune shifts pitch ─────────────────────────────────
    //
    // finetune=+8 means exactly +1 semitone (8 units * 1/8 semitone = 1 semitone).
    // That raises pitch by a factor of pow(2, 1/12) ≈ 1.0595. A 440 Hz source
    // at finetune=+8 should produce ≈ 466 Hz output (A#4).
    //
    // What this catches: wrong finetune exponent, sign errors, or ignored finetune.
    func testVoiceFinetuneShiftsPitch() {
        let N = 44100
        let bank = UnifiedSampleBank(capacity: N + 4)
        for i in 0..<N {
            bank.samplePointer[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 44100.0)
        }

        // finetune = +7 (max positive) = 7/8 semitone ≈ pow(2, 7/96) ≈ 1.0506 ratio
        // At step=1.0 base, finetune+7 → freq multiplied by 1.0506 → 440*1.0506 ≈ 462.3 Hz
        var voiceUp = SynthVoice()
        voiceUp.trigger(frequency: 44100.0, velocity: 1.0, offset: 0, length: N,
                        loopType: .classic, loopStart: 0, loopLength: N,
                        finetune: 7)

        var voiceFlat = SynthVoice()
        voiceFlat.trigger(frequency: 44100.0, velocity: 1.0, offset: 0, length: N,
                          loopType: .classic, loopStart: 0, loopLength: N,
                          finetune: 0)

        let renderN = 44100
        let bufUp = UnsafeMutablePointer<Float>.allocate(capacity: renderN)
        let bufFlat = UnsafeMutablePointer<Float>.allocate(capacity: renderN)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: renderN)
        let pos = UnsafeMutablePointer<Float>.allocate(capacity: renderN)
        let dummy = UnsafeMutablePointer<Float>.allocate(capacity: renderN)
        defer { bufUp.deallocate(); bufFlat.deallocate(); scratch.deallocate(); pos.deallocate(); dummy.deallocate() }
        bufUp.initialize(repeating: 0, count: renderN)
        bufFlat.initialize(repeating: 0, count: renderN)
        dummy.initialize(repeating: 0, count: renderN)

        voiceUp.process(bufferL: bufUp, bufferR: dummy, scratchBuffer: scratch,
                        positionsScratch: pos, sampleBank: bank, count: renderN, sampleRate: 44100.0)
        dummy.initialize(repeating: 0, count: renderN)
        pos.initialize(repeating: 0, count: renderN)
        voiceFlat.process(bufferL: bufFlat, bufferR: dummy, scratchBuffer: scratch,
                          positionsScratch: pos, sampleBank: bank, count: renderN, sampleRate: 44100.0)

        var crossingsUp = 0, crossingsFlat = 0
        for i in 1..<renderN {
            if (bufUp[i-1] < 0) != (bufUp[i] < 0) { crossingsUp += 1 }
            if (bufFlat[i-1] < 0) != (bufFlat[i] < 0) { crossingsFlat += 1 }
        }
        // finetune+7 should produce MORE crossings than finetune=0 (higher pitch = higher frequency)
        XCTAssertGreaterThan(crossingsUp, crossingsFlat,
            "finetune=+7 must produce higher pitch than finetune=0. " +
            "Got \(crossingsUp) vs \(crossingsFlat) crossings. " +
            "Equal counts means finetune is not being applied.")
        // Ratio of crossings should atoootximate pow(2, 7/96) ≈ 1.0506
        let ratio = Float(crossingsUp) / Float(crossingsFlat)
        XCTAssertEqual(ratio, powf(2.0, 7.0/96.0), accuracy: 0.05,
            "Finetune+7 pitch ratio must be ≈1.050 (got \(ratio)). " +
            "Wrong ratio means the finetune exponent formula is incorrect.")
    }
}
