import XCTest
import Foundation
import AVFoundation
@testable import ToooT_UI
@testable import ToooT_Core
@testable import ToooT_IO

final class TranspilerTroubleshootingTests: XCTestCase {
    
    @MainActor
    func testLoadAndTranspileMod() async throws {
        let modURL = URL(fileURLWithPath: "../Examples/Carbon Example/small MOD Music.mod")
        print("🔍 Attempting to load MOD file from: \(modURL.path)")
        
        let transpiler = FormatTranspiler(sourceURL: modURL)
        let instrumentMap = transpiler.parseInstruments(from: modURL)
        let rowMapArray = try transpiler.createSnapshot(from: modURL)

        let engine = try AudioEngine(componentDescription: AudioComponentDescription())
        try transpiler.loadSamples(from: modURL, into: engine)

        let slab: UnsafeMutablePointer<TrackerEvent> = .allocate(capacity: kMaxChannels * 64 * 100)
        slab.initialize(repeating: .empty, count: kMaxChannels * 64 * 100)
        
        let instBank: UnsafeMutablePointer<Instrument> = .allocate(capacity: 256)
        instBank.initialize(repeating: Instrument(), count: 256)
        for (id, inst) in instrumentMap {
            if id >= 0 && id < 256 { instBank[id] = inst }
        }
        
        let emptyEnvs: UnsafeMutablePointer<Int32> = .allocate(capacity: 256)
        emptyEnvs.initialize(repeating: 0, count: 256)

        rowMapArray.withUnsafeBufferPointer { src in
            slab.update(from: src.baseAddress!, count: min(src.count, kMaxChannels * 64 * 100))
        }
        
        let snap = SongSnapshot(
            events: slab, 
            instruments: instBank, 
            orderList: [0], 
            songLength: 1,
            volEnv: emptyEnvs,
            panEnv: emptyEnvs,
            pitchEnv: emptyEnvs
        )
        
        engine.updateSongSnapshot(snap)
        engine.sharedStatePtr.pointee.isPlaying = 1
        engine.sharedStatePtr.pointee.masterVolume = 1.0
        
        let renderBlock = engine.internalRenderBlock
        var timeStamp = AudioTimeStamp()
        var actionFlags = AudioUnitRenderActionFlags()
        
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(kMaxChannels)) else {
            XCTFail("Could not create pcmBuffer")
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(kMaxChannels)
        
        var totalNonZero = 0
        for cycle in 0..<50 {
            _ = renderBlock(&actionFlags, &timeStamp, AUAudioFrameCount(kMaxChannels), 0, pcmBuffer.mutableAudioBufferList, nil, nil)
            
            var cycleNonZero = 0
            if let ptr = pcmBuffer.floatChannelData?[0] {
                for i in 0..<kMaxChannels {
                    if abs(ptr[i]) > 0.0001 { cycleNonZero += 1 }
                }
            }
            totalNonZero += cycleNonZero
            // print("   - Cycle \(cycle): row \(engine.sharedStatePtr.pointee.currentEngineRow), non-zero: \(cycleNonZero)")
        }
        
        print("🔍 Total Non-Zero Samples generated: \(totalNonZero)")
        
        // Cleanup
        slab.deallocate()
        instBank.deallocate()
        emptyEnvs.deallocate()
    }
}
