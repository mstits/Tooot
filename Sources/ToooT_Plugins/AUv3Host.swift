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
///
/// `init()` no longer eagerly scans. The first launch with a fresh AUv3
/// cache can take 1–3 s for `AVAudioUnitComponentManager` to enumerate
/// every installed plug-in; doing that synchronously inside Timeline's
/// init blocks the main actor through cold launch. Callers either:
///
///   1. Call `discoverPlugins()` synchronously (UATRunner does this — it
///      wants the result deterministically).
///   2. `await discoverPluginsAsync()` from a background Task during
///      cold launch (Timeline does this — UI gets populated when the
///      scan finishes, no main-thread block).
///   3. Read `availablePlugins` directly — empty until discovery has run.
public final class AUv3HostManager: @unchecked Sendable {
    public private(set) var availablePlugins: [AVAudioUnitComponent] = []
    public private(set) var hasScanned: Bool = false

    public init() {}

    private static let scanLog = OSLog(
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
        self.hasScanned = true
    }

    /// Off-main-thread scan. Call once during cold launch from a Task —
    /// `availablePlugins` is populated on completion. Safe to call multiple
    /// times; later calls overwrite the previous result.
    public func discoverPluginsAsync() async {
        await Task.detached(priority: .utility) { [self] in
            self.discoverPlugins()
        }.value
    }
}
