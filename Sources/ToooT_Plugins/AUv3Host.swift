/*
 *  PROJECT ToooT (ToooT_Plugins)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *
 *  AUv3 discovery utility.
 *
 *  Real hosting (per-channel insert chains, render-block wiring, state save/load)
 *  lives in `AudioHost` (ToooT_UI). This type exists solely to enumerate the
 *  AVAudioUnitComponent list for browser UIs and UAT coverage.
 */

import Foundation
import AVFoundation
import os.log

/// Discovers external Audio Units (instruments and effects).
public final class AUv3HostManager: @unchecked Sendable {
    public private(set) var availablePlugins: [AVAudioUnitComponent] = []

    public init() {
        discoverPlugins()
    }

    nonisolated(unsafe) private static let scanLog = OSLog(
        subsystem: "com.apple.ProjectToooT", category: "ColdLaunch")

    public func discoverPlugins() {
        let id = OSSignpostID(log: Self.scanLog)
        os_signpost(.begin, log: Self.scanLog, name: "AUv3 scan", signpostID: id)
        defer { os_signpost(.end, log: Self.scanLog, name: "AUv3 scan", signpostID: id) }

        let effectDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let instrumentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let manager = AVAudioUnitComponentManager.shared()
        self.availablePlugins = manager.components(matching: effectDesc)
                              + manager.components(matching: instrumentDesc)
    }
}
