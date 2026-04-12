import XCTest
import Foundation
import AVFoundation
@testable import ToooT_UI
@testable import ToooT_Core

final class StabilityTests: XCTestCase {
    
    @MainActor
    func testAtomicBridgeStability() async {
        print("🚀 Starting Atomic Bridge Stability Test...")
        
        let state = PlaybackState()
        let engine = try! AudioEngine(componentDescription: AudioComponentDescription())
        
        // Rapid instantiation and destruction
        for i in 0..<50 {
            let timeline = Timeline(state: state, engine: engine, renderNode: engine.renderNode)
            timeline.play()
            
            // Prove that writing to the raw pointer from a concurrent thread
            // doesn't crash the MainActor polling.
            DispatchQueue.global().async {
                engine.sharedStatePtr.pointee.currentEngineRow = Int32(i % 64)
            }
            
            try? await Task.sleep(nanoseconds: 5_000_000)
            
            if i % 10 == 0 { print("  Cycle \(i) atomic stable...") }
        }
        
        print("✅ Stability Test Passed: No Swift metadata traps.")
    }
    
    @MainActor
    func testDiagnoseRender() async throws {
        let modURL = URL(fileURLWithPath: "../Examples/Carbon Example/small MOD Music.mod")
        print("🔍 DIAGNOSE: Attempting to load MOD file from: \(modURL.path)")
        
        let engine = try AudioEngine(componentDescription: AudioComponentDescription())
        engine.sharedStatePtr.pointee.isPlaying = 1
        engine.sharedStatePtr.pointee.masterVolume = 1.0
        
        // Setup a valid snapshot
        let slab: UnsafeMutablePointer<TrackerEvent> = .allocate(capacity: kMaxChannels * 64 * 100)
        slab.initialize(repeating: .empty, count: kMaxChannels * 64 * 100)
        let instBank: UnsafeMutablePointer<Instrument> = .allocate(capacity: 256)
        instBank.initialize(repeating: Instrument(), count: 256)
        let emptyEnvs: UnsafeMutablePointer<Int32> = .allocate(capacity: 256)
        emptyEnvs.initialize(repeating: 0, count: 256)
        
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
        
        let renderBlock = engine.internalRenderBlock
        var timeStamp = AudioTimeStamp()
        var actionFlags = AudioUnitRenderActionFlags()
        
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 100) else {
            XCTFail("Could not create pcmBuffer")
            return
        }
        pcmBuffer.frameLength = 100
        
        _ = renderBlock(&actionFlags, &timeStamp, 100, 0, pcmBuffer.mutableAudioBufferList, nil, nil)
        
        if let ptr = pcmBuffer.floatChannelData?[0] {
            print("🔍 DIAGNOSE: First 20 rendered samples (L channel):")
            var renderStr = ""
            for i in 0..<20 {
                renderStr += "\(ptr[i]), "
            }
            print(renderStr)
        }
        
        slab.deallocate()
        instBank.deallocate()
        emptyEnvs.deallocate()
    }
}
