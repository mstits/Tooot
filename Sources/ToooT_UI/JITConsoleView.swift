/*
 *  PROJECT ToooT (ToooT_UI)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  ToooTShell JIT 3.0 — High-Performance DAW Scripting.
 */

import SwiftUI
import Foundation
import ToooT_Core
import Accelerate

// MARK: - ToooTShell Engine

@MainActor
public final class JITInterpreter: ObservableObject {
    @Published var consoleOutput: String = "ToooTShell v3.0 [Apple Silicon Optimized]\nType 'help' for technical reference.\n"
    @Published var variables: [String: Double] = [:]
    @Published var macros: [String: String] = [:]
    
    private unowned var state: PlaybackState
    private unowned var timeline: Timeline?
    
    public init(state: PlaybackState, timeline: Timeline?) {
        self.state = state
        self.timeline = timeline
    }
    
    func appendOutput(_ line: String, isError: Bool = false) {
        let prefix = isError ? "![ERR] " : ""
        consoleOutput += prefix + line + "\n"
    }
    
    public func run(_ script: String) {
        let lines = script.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("//") { i += 1; continue }
            if line.lowercased().hasPrefix("loop ") {
                let tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if tokens.count >= 2, let count = Int(resolve(tokens[1])) {
                    var block = ""; var depth = 0; i += 1
                    while i < lines.count {
                        let l = lines[i]; if l.contains("{") { depth += 1 }; if l.contains("}") { if depth == 0 { break }; depth -= 1 }; block += l + "\n"; i += 1
                    }
                    for _ in 0..<count { run(block) }
                }
            } else { executeLine(line) }
            i += 1
        }
    }
    
    private func executeLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$") && trimmed.contains("=") {
            let parts = trimmed.components(separatedBy: "=")
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let expr = parts[1].trimmingCharacters(in: .whitespaces)
            if let val = evaluate(expr) { variables[name] = val; return }
        }
        let toks = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !toks.isEmpty else { return }
        let cmd = toks[0].lowercased(); let args = toks.dropFirst().map { resolve($0) }
        switch cmd {
        case "print": appendOutput(args.joined(separator: " "))
        case "bpm": handleBPM(args)
        case "vol", "volume": handleVolume(args)
        case "ch": handleChannel(args)
        case "euclid": handleEuclid(args)
        case "tidal": handleTidal(args, raw: trimmed)
        case "note": handleNote(args)
        case "clear": handleClear(args)
        case "transpose": handleTranspose(args)
        case "humanize": handleHumanize(args)
        case "evolve": handleEvolve(args)
        case "shuffle": handleShuffle(args)
        case "reverse": handleReverse(args)
        case "fill": handleFill(args)
        case "copy": handleCopy(args)
        case "arp": handleArp(args)
        case "fade": handleFade(args)
        case "inst": handleInst(args)
        case "undo": state.undo(); refresh()
        case "redo": state.redo(); refresh()
        case "play": NotificationCenter.default.post(name: NSNotification.Name("TransportToggle"), object: nil)
        case "stop": NotificationCenter.default.post(name: NSNotification.Name("TransportStop"), object: nil)
        case "status": printStatus()
        case "help", "?": printHelp()
        case "macro": handleMacro(trimmed)
        default: if let macro = macros[cmd] { run(macro) } else { appendOutput("Unknown command: \(cmd)", isError: true) }
        }
    }
    
    private func handleBPM(_ args: [String]) { if args.count >= 1, let n = Int(args[0]) { timeline?.setBPM(n.clamped(to: 32...255)); refresh() } else { appendOutput("BPM: \(state.bpm)") } }
    private func handleVolume(_ args: [String]) { if args.count >= 1, let f = Double(args[0]) { state.masterVolume = f.clamped(to: 0...1); refresh() } }
    private func handleChannel(_ args: [String]) {
        guard args.count >= 2, let ch = Int(args[0]), ch >= 1, ch <= kMaxChannels else { return }
        let sub = args[1].lowercased()
        if sub == "vol" && args.count >= 3 { state.setVolume(Float(args[2]) ?? 1.0, for: ch-1) }
        else if sub == "pan" && args.count >= 3 { state.setPan(Float(args[2]) ?? 0.5, for: ch-1) }
        else if sub == "mute" { state.setMute(true, for: ch-1) }
        else if sub == "unmute" { state.setMute(false, for: ch-1) }
        else if sub == "solo" { state.setSolo(true, for: ch-1) }
        refresh()
    }
    private func handleEuclid(_ args: [String]) {
        guard args.count >= 4, let ch = Int(args[0]), let p = Int(args[1]), let s = Int(args[2]), let n = Float(args[3]) else { return }
        let pattern = EuclideanGenerator.generate(pulses: p, steps: s); state.snapshotForUndo()
        let freq = n <= 127 ? midiToHz(n) : n
        for i in 0..<min(s, 64) { let idx = (state.currentPattern * 64 + i) * kMaxChannels + (ch-1); state.sequencerData.events[idx] = pattern[i] ? TrackerEvent(type: .noteOn, channel: UInt8(ch-1), instrument: UInt8(state.selectedInstrument), value1: freq) : .empty }
        refresh()
    }
    private func handleNote(_ args: [String]) { guard args.count >= 3, let row = Int(args[0]), let ch = Int(args[1]), let n = Float(args[2]) else { return }; state.snapshotForUndo(); let freq = n <= 127 ? midiToHz(n) : n; let idx = (state.currentPattern * 64 + row) * kMaxChannels + (ch-1); state.sequencerData.events[idx] = TrackerEvent(type: .noteOn, channel: UInt8(ch-1), instrument: UInt8(state.selectedInstrument), value1: freq); refresh() }
    private func handleClear(_ args: [String]) { if args.isEmpty { consoleOutput = "" } else if args[0] == "ch" && args.count >= 2, let ch = Int(args[1]) { state.snapshotForUndo(); for r in 0..<64 { state.sequencerData.events[(state.currentPattern * 64 + r) * kMaxChannels + (ch-1)] = .empty }; refresh() } }
    private func handleTranspose(_ args: [String]) {
        guard args.count >= 2, let ch = Int(args[0]), let semi = Float(args[1]) else { return }; state.snapshotForUndo()
        for r in 0..<64 { let idx = (state.currentPattern * 64 + r) * kMaxChannels + (ch-1); if state.sequencerData.events[idx].type == .noteOn { let freq = state.sequencerData.events[idx].value1; let m = 12.0 * log2(Double(freq) / 440.0) + 69.0; state.sequencerData.events[idx].value1 = Float(440.0 * pow(2.0, (m + Double(semi) - 69.0) / 12.0)) } }
        refresh()
    }
    private func handleHumanize(_ args: [String]) { guard args.count >= 2, let ch = Int(args[0]), let amt = Float(args[1]) else { return }; state.snapshotForUndo(); for r in 0..<64 { let idx = (state.currentPattern * 64 + r) * kMaxChannels + (ch-1); if state.sequencerData.events[idx].type == .noteOn { state.sequencerData.events[idx].value2 = (state.sequencerData.events[idx].value2 + Float.random(in: -amt...amt)).clamped(to: 0.1...1.0) } }; refresh() }
    private func handleEvolve(_ args: [String]) { guard args.count >= 2, let ch = Int(args[0]), let amt = Float(args[1]) else { return }; state.snapshotForUndo(); for r in 0..<64 { let idx = (state.currentPattern * 64 + r) * kMaxChannels + (ch-1); if state.sequencerData.events[idx].type == .noteOn && Float.random(in: 0...1) < amt { let m = 12.0 * log2(Double(state.sequencerData.events[idx].value1) / 440.0) + 69.0; state.sequencerData.events[idx].value1 = Float(440.0 * pow(2.0, (m + Double([-1,1].randomElement()!) - 69.0) / 12.0)) } }; refresh() }
    private func handleShuffle(_ args: [String]) { guard args.count >= 1, let ch = Int(args[0]) else { return }; state.snapshotForUndo(); var chunk = [TrackerEvent](); for r in 0..<64 { chunk.append(state.sequencerData.events[(state.currentPattern * 64 + r) * kMaxChannels + (ch-1)]) }; chunk.shuffle(); for r in 0..<64 { state.sequencerData.events[(state.currentPattern * 64 + r) * kMaxChannels + (ch - 1)] = chunk[r] }; refresh() }
    private func handleReverse(_ args: [String]) { guard args.count >= 1, let ch = Int(args[0]) else { return }; state.snapshotForUndo(); var chunk = [TrackerEvent](); for r in 0..<64 { chunk.append(state.sequencerData.events[(state.currentPattern * 64 + r) * kMaxChannels + (ch-1)]) }; chunk.reverse(); for r in 0..<64 { state.sequencerData.events[(state.currentPattern * 64 + r) * kMaxChannels + (ch - 1)] = chunk[r] }; refresh() }
    private func handleFill(_ args: [String]) {
        guard args.count >= 3, let ch = Int(args[0]), let n = Float(args[1]), let step = Int(args[2]), step > 0 else {
            appendOutput("Usage: fill <channel> <note/hz> <step> [rows]", isError: true); return
        }
        let totalRows = args.count >= 4 ? (Int(args[3]) ?? 64) : 64
        state.snapshotForUndo()
        let freq = n <= 127 ? midiToHz(n) : n
        for r in 0..<min(totalRows, 64) {
            let idx = (state.currentPattern * 64 + r) * kMaxChannels + (ch - 1)
            if r % step == 0 {
                state.sequencerData.events[idx] = TrackerEvent(type: .noteOn, channel: UInt8(ch-1), instrument: UInt8(state.selectedInstrument), value1: freq)
            } else {
                state.sequencerData.events[idx] = .empty
            }
        }
        appendOutput("Filled ch \(ch) with note \(Int(n)) every \(step) rows.")
        refresh()
    }
    private func handleCopy(_ args: [String]) {
        guard args.count >= 2, let src = Int(args[0]), let dst = Int(args[1]) else { appendOutput("Usage: copy <src_ch> <dest_ch>", isError: true); return }
        state.snapshotForUndo()
        for r in 0..<64 {
            let srcIdx = (state.currentPattern * 64 + r) * kMaxChannels + (src - 1)
            let dstIdx = (state.currentPattern * 64 + r) * kMaxChannels + (dst - 1)
            state.sequencerData.events[dstIdx] = state.sequencerData.events[srcIdx]
        }
        appendOutput("Copied ch \(src) to ch \(dst)")
        refresh()
    }
    private func handleArp(_ args: [String]) {
        guard args.count >= 4, let ch = Int(args[0]), let base = Float(args[1]), let step = Int(args[2]), step > 0 else { appendOutput("Usage: arp <ch> <base> <step> <semi...>", isError: true); return }
        let semis = args.dropFirst(3).compactMap { Float($0) }
        guard !semis.isEmpty else { return }
        state.snapshotForUndo()
        var semiIdx = 0
        for r in stride(from: 0, to: 64, by: step) {
            let idx = (state.currentPattern * 64 + r) * kMaxChannels + (ch - 1)
            let freq = midiToHz(base + semis[semiIdx])
            state.sequencerData.events[idx] = TrackerEvent(type: .noteOn, channel: UInt8(ch-1), instrument: UInt8(state.selectedInstrument), value1: freq)
            semiIdx = (semiIdx + 1) % semis.count
        }
        appendOutput("Arp generated on ch \(ch)")
        refresh()
    }
    private func handleFade(_ args: [String]) {
        guard args.count >= 2, let ch = Int(args[0]) else { appendOutput("Usage: fade <ch> <in|out>", isError: true); return }
        let type = args[1].lowercased()
        state.snapshotForUndo()
        for r in 0..<64 {
            let idx = (state.currentPattern * 64 + r) * kMaxChannels + (ch - 1)
            if state.sequencerData.events[idx].type == .noteOn {
                let vol = type == "in" ? Float(r) / 63.0 : 1.0 - (Float(r) / 63.0)
                state.sequencerData.events[idx].value2 = max(0.1, vol)
            }
        }
        appendOutput("Faded \(type) ch \(ch)")
        refresh()
    }
    private func handleInst(_ args: [String]) {
        guard args.count >= 2, let id = Int(args[0]) else { return }
        if args[1].lowercased() == "name" && args.count >= 3 {
            var inst = state.instruments[id] ?? Instrument()
            inst.nameString = args.dropFirst(2).joined(separator: " ")
            state.instruments[id] = inst
            appendOutput("Inst \(id) renamed")
        }
    }
    private func handleTidal(_ args: [String], raw: String) {
        guard args.count >= 1, let ch = Int(args[0]) else { return }; guard let first = raw.firstIndex(of: "\""), let last = raw.lastIndex(of: "\"") else { return }; let pattern = String(raw[raw.index(after: first)..<last]); let steps = pattern.components(separatedBy: .whitespaces).filter { !$0.isEmpty }; state.snapshotForUndo()
        for r in 0..<64 { state.sequencerData.events[(state.currentPattern * 64 + r) * kMaxChannels + ch-1] = .empty }; let rowStep = 64.0 / Double(steps.count)
        for (i, s) in steps.enumerated() { if s == "~" { continue }; let row = Int(round(Double(i) * rowStep)); if row >= 64 { continue }; var f: Float = 0; switch s.lowercased() { case "bd": f = midiToHz(36); case "sn": f = midiToHz(38); case "hh": f = midiToHz(42); default: if let v = Float(s) { f = v <= 127 ? midiToHz(v) : v } else { continue } }; state.sequencerData.events[(state.currentPattern * 64 + row) * kMaxChannels + ch-1] = TrackerEvent(type: .noteOn, channel: UInt8(ch-1), instrument: UInt8(state.selectedInstrument), value1: f) }
        refresh()
    }
    private func handleMacro(_ raw: String) { let parts = raw.components(separatedBy: "="); if parts.count >= 2 { let name = parts[0].replacingOccurrences(of: "macro ", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces).lowercased(); macros[name] = parts.dropFirst().joined(separator: "=").replacingOccurrences(of: ";", with: "\n"); appendOutput("Macro '\(name)' defined.") } }
    private func resolve(_ token: String) -> String { if token.hasPrefix("$"), let val = variables[token] { return "\(val)" }; return token }
    private func evaluate(_ expr: String) -> Double? { var processed = expr; for (key, val) in variables { processed = processed.replacingOccurrences(of: key, with: "\(val)") }; let expression = NSExpression(format: processed); return expression.expressionValue(with: nil, context: nil) as? Double }
    private func refresh() { state.textureInvalidationTrigger += 1; timeline?.publishSnapshot() }
    private func midiToHz(_ m: Float) -> Float { Float(440.0 * pow(2.0, (Double(m) - 69.0) / 12.0)) }
    private func printStatus() { appendOutput("── Engine Status ──\nBPM: \(state.bpm) | Voices: \(state.activeVoices)\nVolume: \(Int(state.masterVolume*100))% | Peak: \(String(format: "%.2f", state.peakLevel))\n───────────────────") }
    private func printHelp() { 
        let helpText = """
        ── ToooTShell v3 Reference ──────────────────────────────────────
        [ CORE SYNTAX ]
        $var = expr               : Define variables (e.g., $x = 36 + 12)
        loop N { cmds }           : Iteration block
        macro name = cmd1; cmd2   : Define custom multi-command macros

        [ SEQUENCING ]
        fill <ch> <note> <step>   : Step-sequence (e.g., fill 1 36 4)
        arp <ch> <base> <s> <...> : Arpeggiator (e.g., arp 1 60 2 0 4 7)
        tidal <ch> "bd ~ sn hh"   : TidalCycles-style beat parsing
        euclid <ch> <p> <s> <note>: Euclidean rhythms (p:pulses, s:steps)
        copy <src_ch> <dest_ch>   : Clone channel events
        clear ch <n>              : Erase all events on channel <n>

        [ TRANSFORMS ]
        transpose <ch> <semi>     : Shift pitch by semitones
        humanize <ch> <amt>       : Randomize timing/velocity
        evolve <ch> <prob>        : Procedurally alter notes
        shuffle <ch>              : Randomize event order
        reverse <ch>              : Reverse event order
        fade <ch> <in|out>        : Linear velocity fade

        [ MIXER & ENGINE ]
        ch <n> vol|pan <val>      : Adjust channel mix
        ch <n> mute|solo|unmute   : Channel toggles
        inst <id> name <str>      : Rename instrument
        bpm <n> / volume <n>      : Master transport config
        play / stop / undo / redo : Transport controls
        ─────────────────────────────────────────────────────────────────
        """
        appendOutput(helpText) 
    }
}

@MainActor
public struct JITConsoleView: View {
    @Bindable var state: PlaybackState; @StateObject private var interpreter: JITInterpreter
    @State private var scriptInput: String = "// ToooTShell v3\nloop 4 {\n  $n = 36 + 12\n  euclid 1 3 8 $n\n  print \"Loop Iterated\"\n}\nstatus"
    @State private var singleLine: String = ""; @FocusState private var isTextFieldFocused: Bool
    public init(state: PlaybackState, timeline: Timeline?) { self.state = state; self._interpreter = StateObject(wrappedValue: JITInterpreter(state: state, timeline: timeline)) }
    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) { headerView; outputLogView; replView; Divider().background(Color.green.opacity(0.2)); scriptEditorView }.padding(10)
            sidebarView
        }.background(Color(white: 0.08)).onAppear { isTextFieldFocused = true }
    }
    private var headerView: some View { HStack { Image(systemName: "terminal.fill").foregroundColor(.green); Text("ToooTShell JIT 3.0").font(.system(size: 11, weight: .black, design: .monospaced)).foregroundColor(.green); Spacer(); Button("CLEAR LOG") { interpreter.consoleOutput = "" }.font(.system(size: 8, weight: .bold)).buttonStyle(.plain).foregroundColor(.gray) } }
    private var outputLogView: some View { ScrollViewReader { proxy in ScrollView { Text(interpreter.consoleOutput).font(.system(size: 10, design: .monospaced)).foregroundColor(.green.opacity(0.85)).frame(maxWidth: .infinity, alignment: .leading).id("bottom") }.frame(minHeight: 150, maxHeight: 400).background(Color.black).cornerRadius(6).onChange(of: interpreter.consoleOutput) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } } }
    private var replView: some View { HStack(spacing: 6) { Text(">").foregroundColor(.green).font(.system(size: 11, weight: .bold, design: .monospaced)); TextField("Enter command...", text: $singleLine).font(.system(size: 11, design: .monospaced)).foregroundColor(.green).textFieldStyle(.plain).focused($isTextFieldFocused).onSubmit { guard !singleLine.isEmpty else { return }; interpreter.appendOutput("> \(singleLine)"); interpreter.run(singleLine); singleLine = ""; isTextFieldFocused = true } }.padding(8).background(Color.black).cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.3), lineWidth: 1)) }
    private var scriptEditorView: some View { VStack(alignment: .leading, spacing: 4) { HStack { Text("SCRIPT BATCH").font(.system(size: 9, weight: .bold)).foregroundColor(.gray); Spacer(); Button("RUN SCRIPT") { interpreter.run(scriptInput) }.font(.system(size: 9, weight: .bold)).tint(.green).buttonStyle(.borderedProminent) }; TextEditor(text: $scriptInput).font(.system(size: 10, design: .monospaced)).foregroundColor(.green).scrollContentBackground(.hidden).background(Color.black).cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.2), lineWidth: 1)).frame(minHeight: 120) } }
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SHELL STATE").font(.system(size: 9, weight: .black)).foregroundColor(.gray)
            ScrollView { VStack(alignment: .leading, spacing: 16) { StateSection(title: "VARS", items: interpreter.variables.keys.sorted().map { ($0, "\(String(format: "%.2f", interpreter.variables[$0]!))") }, color: .green); StateSection(title: "MACROS", items: interpreter.macros.keys.sorted().map { ($0, "") }, color: .cyan); VStack(alignment: .leading, spacing: 10) { Text("EXAMPLES").font(.system(size: 8, weight: .bold)).foregroundColor(.purple.opacity(0.5)); ExampleItem(name: "Techno Generator", code: "$k=36\nloop 4 {\n  euclid 1 5 16 $k\n  $k = $k + 1\n}", input: $scriptInput); ExampleItem(name: "Acid Shuffle", code: "fill 1 48 4\nloop 8 {\n  shuffle 1\n  transpose 1 1\n}", input: $scriptInput) } } }
            Spacer(); Button("RESET ALL") { interpreter.variables.removeAll(); interpreter.macros.removeAll() }.font(.system(size: 8, weight: .bold)).buttonStyle(.bordered)
        }.frame(width: 150).padding(10).background(Color.black.opacity(0.2))
    }
}

struct StateSection: View {
    let title: String; let items: [(String, String)]; let color: Color
    var body: some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 8, weight: .bold)).foregroundColor(color.opacity(0.5)); ForEach(items, id: \.0) { name, val in HStack { Text(name).foregroundColor(color); Spacer(); Text(val).foregroundColor(.white) }.font(.system(size: 9, design: .monospaced)) } } }
}

struct ExampleItem: View {
    let name: String; let code: String; @Binding var input: String
    var body: some View { Text(name).font(.system(size: 9, design: .rounded)).foregroundColor(.white.opacity(0.8)).onTapGesture { input = "// \(name)\n\(code)" } }
}
