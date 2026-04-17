/*
 *  PROJECT ToooT (ToooT_UI)
 *  ⌘K command palette — fuzzy finder over every command in the DAW.
 *
 *  Inspired by VS Code / Bitwig 5.3 / Ableton Live 12 / Studio One 7.
 *  Works against a central CommandRegistry; each command is
 *  `{ id, title, category, shortcut?, action }`.
 *
 *  Filter algorithm: all query tokens must match the title (case-insensitive
 *  substring). Results ranked by: exact-prefix match > word-prefix > any-position.
 */

import SwiftUI
import AppKit

public struct PaletteCommand: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let category: String
    public let shortcut: String?
    public let action: @MainActor @Sendable () -> Void

    public init(id: String, title: String, category: String = "",
                shortcut: String? = nil,
                action: @MainActor @Sendable @escaping () -> Void) {
        self.id = id; self.title = title; self.category = category
        self.shortcut = shortcut; self.action = action
    }
}

@MainActor
public final class CommandRegistry: ObservableObject {
    @Published public private(set) var commands: [PaletteCommand] = []

    public static let shared = CommandRegistry()

    public init() {}

    public func register(_ command: PaletteCommand) {
        // Replace any existing command with the same id.
        commands.removeAll { $0.id == command.id }
        commands.append(command)
    }

    public func register(contentsOf list: [PaletteCommand]) {
        for c in list { register(c) }
    }

    public func unregister(id: String) {
        commands.removeAll { $0.id == id }
    }

    /// Scored fuzzy match. Returns commands sorted best-first.
    public func match(query: String) -> [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }

        let tokens = q.split(separator: " ").map(String.init)
        var scored: [(PaletteCommand, Int)] = []

        for cmd in commands {
            let haystack = (cmd.title + " " + cmd.category).lowercased()
            // All tokens must appear.
            guard tokens.allSatisfy({ haystack.contains($0) }) else { continue }

            var score = 0
            let titleLower = cmd.title.lowercased()
            for tok in tokens {
                if titleLower.hasPrefix(tok)              { score += 100 }
                else if titleLower.contains(" " + tok)    { score += 50 }   // word-prefix
                else if titleLower.contains(tok)          { score += 10 }
                else                                       { score += 2 }    // matched in category
            }
            // Shorter titles win ties (more specific).
            score -= cmd.title.count / 4
            scored.append((cmd, score))
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }
}

public struct CommandPaletteView: View {
    @StateObject private var registry = CommandRegistry.shared
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    public init() {}

    private var results: [PaletteCommand] {
        Array(registry.match(query: query).prefix(50))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search field — oversized, minimalist.
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("Run command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .regular))
                    .focused($searchFocused)
                    .onSubmit { runSelected() }
                    .onChange(of: query) { _, _ in selectedIndex = 0 }
                Text("⌘K")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)

            Divider()

            // Results list.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, cmd in
                            row(cmd, idx: idx)
                                .id(cmd.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedIndex = idx; runSelected() }
                        }
                        if results.isEmpty {
                            HStack {
                                Text(query.isEmpty ? "Start typing to find a command."
                                                    : "No commands match “\(query)”.")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(16)
                        }
                    }
                }
                .frame(maxHeight: 340)
                .onChange(of: selectedIndex) { _, new in
                    if new < results.count {
                        proxy.scrollTo(results[new].id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 580)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
        .onAppear { searchFocused = true; selectedIndex = 0 }
        .onKeyPress(.upArrow)   { selectedIndex = max(0, selectedIndex - 1); return .handled }
        .onKeyPress(.downArrow) { selectedIndex = min(max(0, results.count - 1), selectedIndex + 1); return .handled }
        .onKeyPress(.escape)    { dismiss(); return .handled }
    }

    @ViewBuilder private func row(_ cmd: PaletteCommand, idx: Int) -> some View {
        let isSelected = idx == selectedIndex
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cmd.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.85))
                if !cmd.category.isEmpty {
                    Text(cmd.category)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if let s = cmd.shortcut {
                Text(s)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary.opacity(isSelected ? 0.5 : 0.3),
                                in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
    }

    private func runSelected() {
        guard selectedIndex < results.count else { return }
        let cmd = results[selectedIndex]
        dismiss()
        Task { @MainActor in cmd.action() }
    }
}

// MARK: - Presentation helper

public extension View {
    /// Binds `isPresented` to a command-palette sheet. Place on the root view.
    func commandPalette(isPresented: Binding<Bool>) -> some View {
        self.sheet(isPresented: isPresented) {
            CommandPaletteView()
                .presentationBackground(.clear)
        }
    }
}

// MARK: - Default command registration

public extension CommandRegistry {
    /// Registers the DAW's built-in commands against a live `PlaybackState`/`AudioHost`/`Timeline`.
    /// Call from the app root once after engine setup. Use weak captures so the registry
    /// doesn't pin the UI model.
    @MainActor
    func registerDefaults(state: PlaybackState, host: AudioHost?, timeline: Timeline?) {
        // Transport
        register(PaletteCommand(id: "transport.play",       title: "Play",  category: "Transport",
                                shortcut: "Space") { [weak host, weak timeline, weak state] in
            guard let host, let timeline, let state else { return }
            if !state.isPlaying { try? host.start(bpm: state.bpm); timeline.play() }
        })
        register(PaletteCommand(id: "transport.stop", title: "Stop",       category: "Transport",
                                shortcut: "Space") { [weak host, weak timeline] in
            timeline?.stop(); host?.stop()
        })
        register(PaletteCommand(id: "transport.play-stop", title: "Play / Stop Toggle",
                                category: "Transport") { [weak host, weak timeline, weak state] in
            guard let host, let timeline, let state else { return }
            if state.isPlaying { timeline.stop(); host.stop() }
            else               { try? host.start(bpm: state.bpm); timeline.play() }
        })

        // Metering + mastering
        register(PaletteCommand(id: "master.limiter.toggle", title: "Toggle Master Limiter",
                                category: "Mastering") { [weak state] in
            state?.isMasterLimiterEnabled.toggle()
        })
        register(PaletteCommand(id: "master.metronome.toggle", title: "Toggle Metronome",
                                category: "Transport") { [weak state] in
            state?.isMetronomeEnabled.toggle()
        })

        // Autosave
        register(PaletteCommand(id: "file.autosave.now", title: "Autosave Now",
                                category: "File") { [weak host, weak state] in
            guard let host, let state else { return }
            host.autosave(state: state)
        })
        register(PaletteCommand(id: "file.autosave.restore", title: "Restore Last Autosave",
                                category: "File") { [weak state] in
            guard let state,
                  let url = AudioHost.latestAutosave(for: state.songTitle) else { return }
            NotificationCenter.default.post(name: NSNotification.Name("LoadModFileURL"), object: url)
        })

        // MIDI panic — kills transport + sends All Notes Off / All Sound Off on every channel.
        register(PaletteCommand(id: "midi.panic", title: "MIDI Panic — All Notes Off",
                                category: "MIDI", shortcut: "⌘.") { [weak host, weak state] in
            guard let host, let state else { return }
            host.midiPanic(state: state)
        })

        // Export
        register(PaletteCommand(id: "file.export.wav", title: "Export Project to WAV…",
                                category: "File") {
            NotificationCenter.default.post(name: NSNotification.Name("ExportAudio"), object: nil)
        })
        register(PaletteCommand(id: "file.export.stems", title: "Export Stems…",
                                category: "File") {
            NotificationCenter.default.post(name: NSNotification.Name("ExportStems"), object: nil)
        })

        // Editing
        register(PaletteCommand(id: "edit.undo", title: "Undo",
                                category: "Edit",  shortcut: "⌘Z") { [weak state] in
            state?.undo()
        })
        register(PaletteCommand(id: "edit.redo", title: "Redo",
                                category: "Edit",  shortcut: "⌘⇧Z") { [weak state] in
            state?.redo()
        })

        // Track operations
        register(PaletteCommand(id: "track.freeze.current", title: "Freeze Current Channel",
                                category: "Track") { [weak host, weak state] in
            guard let host, let state else { return }
            host.freezeChannel(state.selectedChannel, state: state)
        })

        // View
        for tab in WorkbenchTab.allCases {
            register(PaletteCommand(id: "view.\(tab.rawValue)", title: "Open \(tab.rawValue)",
                                    category: "View") { [weak state] in
                state?.activeTab = tab
            })
        }
    }
}
