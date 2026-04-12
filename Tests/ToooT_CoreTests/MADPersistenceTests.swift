import XCTest
import Foundation
import AVFoundation
@testable import ToooT_Core
@testable import ToooT_IO

final class MADPersistenceTests: XCTestCase {
    
    func testSaveAndLoadMAD() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.mad")
        
        // 1. Create mock data
        let slab: UnsafeMutablePointer<TrackerEvent> = .allocate(capacity: kMaxChannels * 64 * 2) // 2 patterns
        slab.initialize(repeating: .empty, count: kMaxChannels * 64 * 2)
        
        // Pattern 0, Row 0, Ch 0: Note On C4 (261.63 Hz)
        slab[0] = TrackerEvent(type: .noteOn, channel: 0, instrument: 1, value1: 261.63)
        
        var inst = Instrument()
        inst.setName("Test Sine")
        let sLen = 1000
        inst.addRegion(SampleRegion(offset: 1 * 262144, length: sLen))
        let instruments = [1: inst]
        
        let bank = UnifiedSampleBank(capacity: 1024 * 1024 * 2)
        // Fill region with 0.5 value
        for i in 0..<sLen {
            bank.samplePointer.advanced(by: 1 * 262144 + i).pointee = 0.5
        }
        
        // 2. Save
        let writer = MADWriter()
        try writer.write(
            events: slab, 
            eventCount: kMaxChannels * 64 * 2,
 
            instruments: instruments, 
            orderList: [0], 
            songLength: 1, 
            sampleBank: bank, 
            to: tempURL
        )
        
        // 3. Load
        let parser = MADParser(sourceURL: tempURL)
        let newBank = UnifiedSampleBank(capacity: 1024 * 1024 * 2)
        let result = try parser.parse(sampleBank: newBank)
        XCTAssertNotNil(result, "MAD parser should recognize its own format")
        let (newSlab, newInsts) = result!
        
        // 4. Verify Patterns
        XCTAssertEqual(newSlab[0].type, .noteOn)
        XCTAssertEqual(newSlab[0].value1, 261.63, accuracy: 0.1)
        
        // 5. Verify Instruments
        XCTAssertEqual(newInsts[1]?.nameString, "Test Sine")
        
        // 6. Verify PCM data
        guard let newInst = newInsts[1], newInst.regionCount > 0 else {
            XCTFail("Parsed instrument should have regions")
            return
        }
        let parsedOffset = newInst.regions.0.offset
        let val = newBank.samplePointer.advanced(by: parsedOffset + 500).pointee
        XCTAssertEqual(val, 0.5, accuracy: 0.01)
        
        // Cleanup
        slab.deallocate()
        newSlab.deallocate()
    }

    @MainActor
    func testLegacyMODIntegration() async throws {
        let modURL = URL(fileURLWithPath: "/Users/stits/Documents/PlayerPRO-master/Examples/Carbon Example/small MOD Music.mod")
        guard FileManager.default.fileExists(atPath: modURL.path) else {
            print("⚠️ Skipping legacy integration test: example MOD not found")
            return
        }

        // 1. Load via MADParser (should return nil)
        let parser = MADParser(sourceURL: modURL)
        let bank = UnifiedSampleBank(capacity: 1024 * 1024 * 16)
        let madResult = try parser.parse(sampleBank: bank)
        XCTAssertNil(madResult, "MADParser should return nil for legacy MOD")

        // 2. Load via Transpiler (Integration check)
        let transpiler = FormatTranspiler(sourceURL: modURL)
        let insts = transpiler.parseInstruments(from: modURL)
        let rowArray = try transpiler.createSnapshot(from: modURL)
        XCTAssertFalse(insts.isEmpty, "Should have loaded legacy instruments")
        XCTAssertFalse(rowArray.isEmpty, "Should have loaded legacy patterns")

        // 3. Verify Audio Rendering
        let engine = try AudioEngine(componentDescription: AudioComponentDescription())
        try transpiler.loadSamples(from: modURL, into: engine)
        
        let slab: UnsafeMutablePointer<TrackerEvent> = .allocate(capacity: kMaxChannels * 64 * 100)
        slab.initialize(repeating: .empty, count: kMaxChannels * 64 * 100)
        for p in 0..<1 {
            for r in 0..<64 {
                for c in 0..<4 {
                    let srcIdx = (p * 64 + r) * kMaxChannels + c
                    let dstIdx = (p * 64 + r) * kMaxChannels + c
                    slab[dstIdx] = rowArray[srcIdx]
                }
            }
        }

        let instBank: UnsafeMutablePointer<Instrument> = .allocate(capacity: 256)
        instBank.initialize(repeating: Instrument(), count: 256)
        for (id, inst) in insts { if id < 256 { instBank[id] = inst } }
        let emptyEnvs: UnsafeMutablePointer<Int32> = .allocate(capacity: 256)
        emptyEnvs.initialize(repeating: 0, count: 256)

        engine.updateSongSnapshot(SongSnapshot(events: slab, instruments: instBank, orderList: [0], songLength: 1, volEnv: emptyEnvs, panEnv: emptyEnvs, pitchEnv: emptyEnvs))
        engine.sharedStatePtr.pointee.isPlaying = 1
        engine.sharedStatePtr.pointee.masterVolume = 1.0

        let renderBlock = engine.internalRenderBlock
        var timeStamp = AudioTimeStamp()
        var actionFlags = AudioUnitRenderActionFlags()
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(kMaxChannels))!
        pcmBuffer.frameLength = AVAudioFrameCount(kMaxChannels)

        var totalNonZero = 0
        for _ in 0..<100 {
            _ = renderBlock(&actionFlags, &timeStamp, AUAudioFrameCount(kMaxChannels), 0, pcmBuffer.mutableAudioBufferList, nil, nil)
            if let ptr = pcmBuffer.floatChannelData?[0] {
                for i in 0..<kMaxChannels { if abs(ptr[i]) > 0.00001 { totalNonZero += 1 } }
            }
        }
        print("🔍 Integration Total Non-Zero Samples: \(totalNonZero)")
        XCTAssertGreaterThan(totalNonZero, 0, "Engine should produce audio from legacy MOD")

        slab.deallocate()
        instBank.deallocate()
        emptyEnvs.deallocate()
    }
}
