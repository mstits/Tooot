/*
 *  PROJECT ToooT (ToooT_CLAP)
 *  BSD-3-licensed CLAP plugin host — discovery, instantiation, real-time processing.
 *
 *  Why CLAP:
 *    • BSD-3-Clause license is MIT-compatible (unlike GPL-only JUCE).
 *    • No vendor registration, no per-host licensing fee, no commercial gate.
 *    • Designed from the ground up for real-time safety.
 *    • Growing ecosystem: Bitwig / Reaper / Ardour / FL all host CLAP; u-he /
 *      FabFilter / Arturia / Surge XT all ship CLAP builds.
 */

import Foundation
import ToooT_CLAP_C

/// Describes a CLAP plugin discovered on disk but not yet instantiated.
public struct CLAPPluginInfo: Identifiable, Sendable {
    public var id: String { pluginID }
    public let bundlePath: String
    public let pluginID:   String
    public let name:       String
    public let vendor:     String
    public let version:    String
    public let features:   [String]
}

/// Discovery + browsing. Cheap to construct; rescans on demand.
public final class CLAPHostManager: @unchecked Sendable {

    public private(set) var availablePlugins: [CLAPPluginInfo] = []

    /// CLAP spec locations on macOS.
    public static let searchPaths: [String] = [
        "/Library/Audio/Plug-Ins/CLAP",
        NSString(string: "~/Library/Audio/Plug-Ins/CLAP").expandingTildeInPath
    ]

    public init() { discoverPlugins() }

    public func discoverPlugins() {
        var found: [CLAPPluginInfo] = []
        let fm = FileManager.default
        for root in Self.searchPaths {
            guard let enumerator = fm.enumerator(atPath: root) else { continue }
            for case let entry as String in enumerator {
                guard entry.hasSuffix(".clap") else { continue }
                let fullPath = (root as NSString).appendingPathComponent(entry)
                found.append(contentsOf: Self.readDescriptors(bundlePath: fullPath))
                enumerator.skipDescendants()
            }
        }
        availablePlugins = found
    }

    private static func readDescriptors(bundlePath: String) -> [CLAPPluginInfo] {
        guard let bundle = tooot_clap_bundle_open(bundlePath) else { return [] }
        defer { tooot_clap_bundle_close(bundle) }
        guard let factoryPtr = tooot_clap_bundle_factory(bundle) else { return [] }
        let factory = factoryPtr.pointee

        guard let getCount = factory.get_plugin_count,
              let getDesc  = factory.get_plugin_descriptor else { return [] }

        let count = Int(getCount(factoryPtr))
        var out: [CLAPPluginInfo] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            guard let descPtr = getDesc(factoryPtr, UInt32(i)) else { continue }
            let desc = descPtr.pointee
            out.append(CLAPPluginInfo(
                bundlePath: bundlePath,
                pluginID:   desc.id.map    { String(cString: $0) } ?? "",
                name:       desc.name.map  { String(cString: $0) } ?? "",
                vendor:     desc.vendor.map{ String(cString: $0) } ?? "",
                version:    desc.version.map{String(cString: $0) } ?? "",
                features:   Self.readFeatures(desc.features)
            ))
        }
        return out
    }

    private static func readFeatures(_ arr: UnsafePointer<UnsafePointer<CChar>?>?) -> [String] {
        guard let arr else { return [] }
        var out: [String] = []
        var i = 0
        while let s = arr[i] {
            out.append(String(cString: s))
            i += 1
        }
        return out
    }
}

/// A loaded CLAP plugin instance. Owns the bundle handle, the plugin vtable,
/// and the host struct it handed to the plugin.
public final class CLAPPluginInstance: @unchecked Sendable {

    public let info: CLAPPluginInfo
    public internal(set) var isActive: Bool = false

    private let bundle: OpaquePointer                          // tooot_clap_bundle_t*
    private let plugin: UnsafePointer<clap_plugin_t>
    private let hostPtr: UnsafeMutablePointer<clap_host_t>
    private let hostStrings: [UnsafeMutablePointer<CChar>]     // strdup'd, freed on deinit

    /// Instantiates `info.pluginID` from its bundle. Initializes, activates, and
    /// starts processing. Returns nil if any step fails.
    public init?(info: CLAPPluginInfo, sampleRate: Double, maxFrames: UInt32) {
        guard let bundle = tooot_clap_bundle_open(info.bundlePath),
              let factoryPtr = tooot_clap_bundle_factory(bundle)
        else { return nil }

        // Allocate + zero-init host struct, then fill.
        let host = UnsafeMutablePointer<clap_host_t>.allocate(capacity: 1)
        host.initialize(to: clap_host_t())

        let nameC    = strdup("PROJECT ToooT")!
        let vendorC  = strdup("Apple Core Audio / Pro Apps Division")!
        let urlC     = strdup("https://github.com/mstits/Tooot")!
        let versionC = strdup("1.0")!
        let strings: [UnsafeMutablePointer<CChar>] = [nameC, vendorC, urlC, versionC]

        host.pointee = clap_host_t(
            clap_version:     clap_version_t(major: 1, minor: 2, revision: 0),
            host_data:        nil,
            name:             UnsafePointer(nameC),
            vendor:           UnsafePointer(vendorC),
            url:              UnsafePointer(urlC),
            version:          UnsafePointer(versionC),
            get_extension:    nil,
            request_restart:  nil,
            request_process:  nil,
            request_callback: nil
        )

        // Create + init + activate.
        let factory = factoryPtr.pointee
        guard let create = factory.create_plugin else {
            Self.cleanup(host: host, strings: strings, bundle: bundle)
            return nil
        }
        let plugin: UnsafePointer<clap_plugin_t>? = info.pluginID.withCString { idC in
            create(factoryPtr, host, idC)
        }
        guard let plugin else {
            Self.cleanup(host: host, strings: strings, bundle: bundle)
            return nil
        }

        if let initFn = plugin.pointee.`init`, !initFn(plugin) {
            plugin.pointee.destroy?(plugin)
            Self.cleanup(host: host, strings: strings, bundle: bundle)
            return nil
        }
        if let activate = plugin.pointee.activate,
           !activate(plugin, sampleRate, 1, maxFrames) {
            plugin.pointee.destroy?(plugin)
            Self.cleanup(host: host, strings: strings, bundle: bundle)
            return nil
        }
        plugin.pointee.start_processing?(plugin)

        self.bundle      = bundle
        self.plugin      = plugin
        self.info        = info
        self.hostPtr     = host
        self.hostStrings = strings
        self.isActive    = true
    }

    deinit {
        if isActive {
            plugin.pointee.stop_processing?(plugin)
            plugin.pointee.deactivate?(plugin)
        }
        plugin.pointee.destroy?(plugin)
        tooot_clap_bundle_close(bundle)
        hostStrings.forEach { free($0) }
        hostPtr.deallocate()
    }

    private static func cleanup(host: UnsafeMutablePointer<clap_host_t>,
                                strings: [UnsafeMutablePointer<CChar>],
                                bundle: OpaquePointer?) {
        tooot_clap_bundle_close(bundle)
        strings.forEach { free($0) }
        host.deallocate()
    }

    /// Processes a block of audio in-place on (bufferL, bufferR).
    /// Called from the CoreAudio render thread — must not allocate.
    public func process(bufferL: UnsafeMutablePointer<Float>,
                        bufferR: UnsafeMutablePointer<Float>,
                        frames:  UInt32) {
        guard isActive, let processFn = plugin.pointee.process else { return }

        var lOpt: UnsafeMutablePointer<Float>? = bufferL
        var rOpt: UnsafeMutablePointer<Float>? = bufferR

        withUnsafeMutablePointer(to: &lOpt) { lpp in
            withUnsafeMutablePointer(to: &rOpt) { rpp in
                // CLAP wants an array of channel pointers: data32[0] = L, data32[1] = R.
                var inChannels:  [UnsafeMutablePointer<Float>?] = [bufferL, bufferR]
                var outChannels: [UnsafeMutablePointer<Float>?] = [bufferL, bufferR]

                inChannels.withUnsafeMutableBufferPointer { inBuf in
                    outChannels.withUnsafeMutableBufferPointer { outBuf in
                        var audioIn = clap_audio_buffer_t(
                            data32: inBuf.baseAddress,
                            data64: nil,
                            channel_count: 2,
                            latency: 0,
                            constant_mask: 0)
                        var audioOut = clap_audio_buffer_t(
                            data32: outBuf.baseAddress,
                            data64: nil,
                            channel_count: 2,
                            latency: 0,
                            constant_mask: 0)

                        var inEvents  = clap_input_events_t(
                            ctx: nil,
                            size: { _ in 0 },
                            get:  { _, _ in nil })
                        var outEvents = clap_output_events_t(
                            ctx: nil,
                            try_push: { _, _ in false })

                        var proc = clap_process_t(
                            steady_time:         0,
                            frames_count:        frames,
                            transport:           nil,
                            audio_inputs:        &audioIn,
                            audio_inputs_count:  1,
                            audio_outputs:       &audioOut,
                            audio_outputs_count: 1,
                            in_events:           &inEvents,
                            out_events:          &outEvents)

                        _ = processFn(plugin, &proc)
                        _ = lpp; _ = rpp
                    }
                }
            }
        }
    }
}
