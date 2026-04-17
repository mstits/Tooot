/*
 *  PROJECT ToooT (Tests)
 *  XCTest coverage of features shipped in the 2026-04-16 push.
 *
 *  Mirrors the assertions UATRunner fires for these same modules — gives us
 *  `swift test` green lights in CI alongside the print-style UAT runner.
 *  Not a full port of UATRunner (that's a session's worth of work on its own)
 *  but covers the highest-churn subsystems.
 */

import XCTest
import Accelerate
@testable import ToooT_Core
@testable import ToooT_Plugins
@testable import ToooT_IO

final class MasterMeterTests: XCTestCase {

    func testInPhaseSineHitsExpectedLUFS() {
        let meter  = MasterMeter()
        let frames = 44100
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { l.deallocate(); r.deallocate() }
        for i in 0..<frames {
            let v = sinf(2.0 * .pi * 1000.0 * Float(i) / 44100.0)
            l[i] = v; r[i] = v
        }
        meter.process(stereoL: l, stereoR: r, frames: frames, sampleRate: 44100)
        XCTAssertGreaterThan(meter.integratedLUFS, -8)
        XCTAssertLessThan(meter.integratedLUFS, 0)
        XCTAssertGreaterThan(meter.phaseCorrelation, 0.95)
    }

    func testResetReturnsFloor() {
        let meter = MasterMeter()
        let frames = 44100
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { l.deallocate(); r.deallocate() }
        for i in 0..<frames { l[i] = sinf(Float(i)); r[i] = sinf(Float(i)) }
        meter.process(stereoL: l, stereoR: r, frames: frames, sampleRate: 44100)
        meter.reset()
        for i in 0..<frames { l[i] = 0; r[i] = 0 }
        meter.process(stereoL: l, stereoR: r, frames: frames, sampleRate: 44100)
        XCTAssertLessThan(meter.integratedLUFS, -60)
    }
}

final class MusicTheoryTests: XCTestCase {

    func testCMajorQuantization() {
        // C major, root C4 (MIDI 60). C# (61) should snap to either C or D.
        let snapped = MusicTheory.quantize(midiNote: 61, rootMIDI: 60, scale: .major)
        XCTAssertTrue(snapped == 60 || snapped == 62, "C# in C major snaps to C or D (got \(snapped))")
    }

    func testPentatonicMinor() {
        // A minor pentatonic includes A, C, D, E, G. B (71) should snap.
        let snapped = MusicTheory.quantize(midiNote: 71, rootMIDI: 69, scale: .pentatonicMinor)
        XCTAssertTrue([69, 72].contains(snapped),
                      "B in A pentatonic minor snaps to A or C (got \(snapped))")
    }

    func testChordGeneration() {
        let cMajor = MusicTheory.chord(rootMIDI: 60, quality: .major)
        XCTAssertEqual(cMajor, [60, 64, 67])
        let cMaj7 = MusicTheory.chord(rootMIDI: 60, quality: .maj7)
        XCTAssertEqual(cMaj7, [60, 64, 67, 71])
    }

    func testFrequencyDomainQuantization() {
        // 445 Hz should quantize up or down to nearest A major note.
        let out = MusicTheory.quantize(frequency: 445, rootMIDI: 69, scale: .major)
        XCTAssertTrue(out > 400 && out < 500, "Quantized output stays in reasonable range (got \(out))")
    }
}

final class ArpeggiatorTests: XCTestCase {

    func testUpModeAscending() {
        var arp = ArpeggiatorEngine()
        arp.mode = .up
        arp.noteOn(60); arp.noteOn(64); arp.noteOn(67)
        XCTAssertEqual(arp.next(), [60])
        XCTAssertEqual(arp.next(), [64])
        XCTAssertEqual(arp.next(), [67])
        XCTAssertEqual(arp.next(), [60])   // wraps
    }

    func testDownMode() {
        var arp = ArpeggiatorEngine()
        arp.mode = .down
        arp.noteOn(60); arp.noteOn(72)
        XCTAssertEqual(arp.next(), [72])
        XCTAssertEqual(arp.next(), [60])
    }

    func testChordModeStacksAll() {
        var arp = ArpeggiatorEngine()
        arp.mode = .chord
        arp.noteOn(60); arp.noteOn(64); arp.noteOn(67)
        XCTAssertEqual(arp.next().sorted(), [60, 64, 67])
    }

    func testHoldModeRetainsNotes() {
        var arp = ArpeggiatorEngine()
        arp.holdMode = true
        arp.noteOn(60); arp.noteOn(64)
        arp.noteOff(60)   // should NOT remove — hold mode
        XCTAssertEqual(arp.size, 2)
    }
}

final class TruePeakLimiterTests: XCTestCase {

    func testRespectsCeiling() throws {
        let cd = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x746c696d,
            componentManufacturer: 0x4d414444,
            componentFlags: 0, componentFlagsMask: 0)
        let limiter = try TruePeakLimiter(componentDescription: cd, options: [])
        try limiter.allocateRenderResources()
        limiter.setCeiling(dBTP: -1.0)

        let frames = 4096
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { l.deallocate(); r.deallocate(); free(abl.unsafeMutablePointer) }

        for i in 0..<frames {
            let v = 0.95 * sinf(2.0 * .pi * 1000.0 * Float(i) / 44100.0)
            l[i] = v; r[i] = v
        }
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                             mData: UnsafeMutableRawPointer(l))
        abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                             mData: UnsafeMutableRawPointer(r))
        var ts = AudioTimeStamp()
        var flags = AudioUnitRenderActionFlags()
        _ = limiter.internalRenderBlock(&flags, &ts, UInt32(frames), 0,
                                        abl.unsafeMutablePointer, nil, nil)

        let meter = MasterMeter()
        meter.process(stereoL: l, stereoR: r, frames: frames, sampleRate: 44100)
        let ceilLinear = powf(10.0, -1.0 / 20.0)
        XCTAssertLessThanOrEqual(meter.truePeak, ceilLinear * 1.02)
    }
}

final class OfflineDSPTests: XCTestCase {

    func testTimeStretchDoublesLength() {
        let srcLen = 8192
        let bank = UnifiedSampleBank(capacity: srcLen * 8)
        for i in 0..<srcLen {
            bank.samplePointer[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 44100.0)
        }
        let out = OfflineDSP.timeStretch(bank: bank, offset: 0, length: srcLen, factor: 2.0)
        XCTAssertGreaterThan(out, Int(Double(srcLen) * 1.5))
    }

    func testPitchShiftDoublesDensity() {
        let srcLen = 8192
        let bank = UnifiedSampleBank(capacity: srcLen * 8)
        for i in 0..<srcLen {
            bank.samplePointer[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 44100.0)
        }
        var srcCross = 0
        for i in 1..<srcLen {
            if (bank.samplePointer[i - 1] < 0) != (bank.samplePointer[i] < 0) { srcCross += 1 }
        }
        let newLen = OfflineDSP.pitchShift(bank: bank, offset: 0, length: srcLen, semitones: 12.0)
        var outCross = 0
        for i in 1..<newLen {
            if (bank.samplePointer[i - 1] < 0) != (bank.samplePointer[i] < 0) { outCross += 1 }
        }
        let ratio = (Float(outCross) / Float(newLen)) / (Float(srcCross) / Float(srcLen))
        XCTAssertGreaterThan(ratio, 1.5)
        XCTAssertLessThan(ratio, 2.5)
    }
}

final class SceneTests: XCTestCase {

    func testBankStoreRetrieve() {
        let bank = SceneBank()
        let scene = SceneSnapshot(name: "Test", channelVolumes: [1, 0.5], masterVolume: 0.8, bpm: 140)
        bank.store(scene, at: 0)
        let loaded = bank.scene(at: 0)
        XCTAssertEqual(loaded?.name, "Test")
        XCTAssertEqual(loaded?.bpm, 140)
    }

    func testSerializationRoundTrip() {
        let bank = SceneBank()
        bank.store(SceneSnapshot(name: "A", bpm: 125), at: 0)
        bank.store(SceneSnapshot(name: "B", bpm: 140), at: 1)
        let data = bank.exportAsPluginStateData()
        XCTAssertEqual(data.count, 2)
        XCTAssertNotNil(data["scene.0"])

        let bank2 = SceneBank()
        bank2.importFromPluginStateData(data)
        XCTAssertEqual(bank2.scene(at: 0)?.name, "A")
        XCTAssertEqual(bank2.scene(at: 1)?.bpm, 140)
    }
}

final class KeyBindingTests: XCTestCase {

    func testPresetShapes() {
        XCTAssertFalse(KeyBindingSet.toooTDefault.bindings.isEmpty)
        XCTAssertFalse(KeyBindingSet.proToolsStyle.bindings.isEmpty)
        XCTAssertFalse(KeyBindingSet.logicStyle.bindings.isEmpty)
        // Space → transport.play-stop in every preset.
        for set in [KeyBindingSet.toooTDefault, .proToolsStyle, .logicStyle] {
            let space = set.bindings.first { $0.commandID == "transport.play-stop" }
            XCTAssertEqual(space?.key, "space")
        }
    }

    func testDisplayString() {
        let kb = KeyBinding(commandID: "x", key: "z", modifiers: ["cmd", "shift"])
        XCTAssertTrue(kb.displayString.contains("⌘"))
        XCTAssertTrue(kb.displayString.contains("⇧"))
    }
}
