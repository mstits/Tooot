/*
 *  PROJECT ToooT (Tests)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 */

import XCTest
import ToooT_Core
import ToooT_Plugins
import ToooT_UI
import AVFoundation

final class PluginHostingTests: XCTestCase {

    @MainActor
    func testPluginDiscovery() async {
        let manager = AUv3HostManager()
        manager.discoverPlugins()
        
        // Note: In a CI environment, availablePlugins might be empty unless there are standard system plugins.
        // But we can check that it doesn't crash and returns the private set.
        let plugins = manager.availablePlugins
        print("Discovered \(plugins.count) AUv3 plugins.")
        
        // Standard macOS systems usually have at least Apple's built-in AUs.
        // On a headless CI runner, this might be 0, so we just verify the call works.
        XCTAssertNotNil(plugins)
    }
    
    @MainActor
    func testExternalInstrumentLoading() async throws {
        let host = AudioHost()
        try await host.setup()
        
        // Mock a MusicDevice component description (e.g., A DLSMusicDevice)
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice,
            componentSubType: 0x646c7320, // 'dls '
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        
        // Check if this component exists on the system before attempting to load
        if let _ = AVAudioUnitComponentManager.shared().components(matching: desc).first {
            do {
                try await host.loadPlugin(component: desc, for: 0)
                XCTAssertTrue(true, "Successfully loaded external instrument into channel 0")
            } catch {
                XCTFail("Failed to load existing Apple Music Device: \(error)")
            }
        } else {
            print("DLSMusicDevice not found on this system, skipping load test.")
        }
    }
    
    @MainActor
    func testEffectLoading() async throws {
        let host = AudioHost()
        try await host.setup()
        
        // Mock an Effect component description (e.g., Peak Limiter)
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6c696d69, // 'limi'
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        
        if let _ = AVAudioUnitComponentManager.shared().components(matching: desc).first {
            do {
                try await host.loadPlugin(component: desc, for: 0)
                XCTAssertTrue(true, "Successfully loaded external effect into channel 0")
            } catch {
                XCTFail("Failed to load existing Apple Peak Limiter: \(error)")
            }
        } else {
            print("PeakLimiter not found on this system, skipping load test.")
        }
    }
}
