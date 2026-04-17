/*
 *  PROJECT ToooT (ToooT_UI)
 *  JavaScriptCore-based scripting API.
 *
 *  Every pro DAW worth using has scripting (Reaper/ReaScript, Bitwig controller
 *  scripts, Studio One macros). JavaScriptCore ships with Apple platforms — no
 *  external runtime to vendor. We expose a minimal but real API so users can
 *  write `.js` files in `~/Library/Application Support/ToooT/scripts/` and run
 *  them from the command palette.
 *
 *  Exposed globals:
 *    state.bpm / state.masterVolume / state.selectedChannel …
 *    state.setNote(row, channel, freq, instrument)
 *    state.fillChannel(channel, pattern)
 *    state.setSend(channel, bus, amount)
 *    state.recallScene(index)
 *    console.log(...)
 *
 *  This is intentionally a small, stable API that won't churn. Scripts shouldn't
 *  need to know about render internals — they're composition + workflow tools.
 */

import Foundation
import JavaScriptCore
import ToooT_Core

@objc public protocol ToooTScriptBridgeExports: JSExport {
    var bpm: Int { get set }
    var masterVolume: Double { get set }
    var selectedChannel: Int { get set }
    var selectedInstrument: Int { get set }
    var currentPattern: Int { get }
    var songLength: Int { get }
    func setNote(_ row: Int, _ channel: Int, _ freq: Double, _ instrument: Int)
    func fillChannel(_ channel: Int, _ freq: Double)
    func clearChannel(_ channel: Int)
    func setSend(_ channel: Int, _ bus: Int, _ amount: Double)
    func setBusVolume(_ bus: Int, _ volume: Double)
    func log(_ s: String)
}

@MainActor
@objc public final class ToooTScriptBridge: NSObject, @preconcurrency ToooTScriptBridgeExports {
    private let state: PlaybackState
    private var logBuffer: [String] = []

    public init(state: PlaybackState) { self.state = state }

    public var consoleOutput: String {
        logBuffer.joined(separator: "\n")
    }

    public var bpm: Int {
        get { state.bpm }
        set { state.bpm = newValue }
    }
    public var masterVolume: Double {
        get { state.masterVolume }
        set { state.masterVolume = newValue }
    }
    public var selectedChannel: Int {
        get { state.selectedChannel }
        set { state.selectedChannel = newValue }
    }
    public var selectedInstrument: Int {
        get { state.selectedInstrument }
        set { state.selectedInstrument = newValue }
    }
    public var currentPattern: Int { state.currentPattern }
    public var songLength: Int     { state.songLength }

    public func setNote(_ row: Int, _ channel: Int, _ freq: Double, _ instrument: Int) {
        guard row >= 0, row < 64, channel >= 0, channel < kMaxChannels else { return }
        let idx = (state.currentPattern * 64 + row) * kMaxChannels + channel
        state.sequencerData.events[idx] = TrackerEvent(
            type: .noteOn, channel: UInt8(channel),
            instrument: UInt8(clamping: instrument),
            value1: Float(freq), value2: 1.0)
        state.textureInvalidationTrigger += 1
    }

    public func fillChannel(_ channel: Int, _ freq: Double) {
        guard channel >= 0, channel < kMaxChannels else { return }
        for row in 0..<64 {
            setNote(row, channel, freq, state.selectedInstrument)
        }
    }

    public func clearChannel(_ channel: Int) {
        guard channel >= 0, channel < kMaxChannels else { return }
        for row in 0..<64 {
            let idx = (state.currentPattern * 64 + row) * kMaxChannels + channel
            state.sequencerData.events[idx] = .empty
        }
        state.textureInvalidationTrigger += 1
    }

    public func setSend(_ channel: Int, _ bus: Int, _ amount: Double) {
        state.setSend(channel: channel, bus: bus, amount: Float(amount))
    }

    public func setBusVolume(_ bus: Int, _ volume: Double) {
        state.setBusVolume(Float(volume), bus: bus)
    }

    public func log(_ s: String) {
        logBuffer.append(s)
        print("[ToooT script] \(s)")
    }
}

@MainActor
public final class ScriptHost {
    public static let shared = ScriptHost()

    /// Runs the given JS source against a PlaybackState. Returns whatever the
    /// script returned (as a string) plus the console log buffer.
    public func run(source: String, state: PlaybackState) -> (result: String, log: String) {
        guard let ctx = JSContext() else { return ("no JS context", "") }
        let bridge = ToooTScriptBridge(state: state)

        // Hook `console.log` and expose `state`.
        let consoleLog: @convention(block) (String) -> Void = { s in bridge.log(s) }
        ctx.setObject(consoleLog, forKeyedSubscript: NSString(string: "__log"))
        ctx.evaluateScript("var console = { log: __log };")
        ctx.setObject(bridge, forKeyedSubscript: NSString(string: "state"))

        ctx.exceptionHandler = { _, exception in
            bridge.log("!! \(exception?.toString() ?? "unknown error")")
        }

        let ret = ctx.evaluateScript(source)
        return (ret?.toString() ?? "undefined", bridge.consoleOutput)
    }

    public func scriptsDirectory() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("ToooT/scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func availableScripts() -> [URL] {
        guard let dir = scriptsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "js" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
