/*
 *  PROJECT ToooT (ToooT_UI)
 *  User-customizable keyboard shortcuts.
 *
 *  Every command registered with the CommandRegistry has an id. Bindings map
 *  ids to (key, modifiers) pairs. A binding set is persisted in UserDefaults
 *  so the user's choices survive relaunch. Preset modes ship three starter
 *  sets — ToooT default, Pro Tools, Logic — so incoming users with muscle
 *  memory from another DAW can keep it.
 */

import SwiftUI
import AppKit
import Foundation

public struct KeyBinding: Codable, Sendable, Hashable {
    public let commandID: String
    public let key: String          // "n", "z", "space", "f1", …
    public let modifiers: [String]  // "cmd", "shift", "alt", "ctrl"

    public init(commandID: String, key: String, modifiers: [String] = []) {
        self.commandID = commandID; self.key = key; self.modifiers = modifiers
    }

    public var displayString: String {
        let mods = modifiers.map { mod -> String in
            switch mod {
            case "cmd":   return "⌘"
            case "shift": return "⇧"
            case "alt":   return "⌥"
            case "ctrl":  return "⌃"
            default:      return mod
            }
        }.joined()
        return mods + key.uppercased()
    }
}

public struct KeyBindingSet: Codable, Sendable {
    public var name: String
    public var bindings: [KeyBinding]
    public init(name: String, bindings: [KeyBinding]) {
        self.name = name; self.bindings = bindings
    }
}

@MainActor
public final class KeyBindingManager: ObservableObject {
    public static let shared = KeyBindingManager()

    @Published public var active: KeyBindingSet {
        didSet { persist() }
    }

    private static let udKey = "com.apple.ProjectToooT.keybindings"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.udKey),
           let decoded = try? JSONDecoder().decode(KeyBindingSet.self, from: data) {
            self.active = decoded
        } else {
            self.active = KeyBindingSet.toooTDefault
        }
    }

    public func binding(for commandID: String) -> KeyBinding? {
        active.bindings.first { $0.commandID == commandID }
    }

    public func commandID(for key: String, modifiers: [String]) -> String? {
        let sorted = Set(modifiers)
        return active.bindings.first {
            $0.key.lowercased() == key.lowercased() &&
            Set($0.modifiers) == sorted
        }?.commandID
    }

    public func apply(preset: KeyBindingSet) {
        self.active = preset
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(active) {
            UserDefaults.standard.set(data, forKey: Self.udKey)
        }
    }
}

// MARK: - Built-in presets

public extension KeyBindingSet {
    static let toooTDefault = KeyBindingSet(name: "ToooT Default", bindings: [
        KeyBinding(commandID: "transport.play-stop", key: "space"),
        KeyBinding(commandID: "edit.undo",           key: "z", modifiers: ["cmd"]),
        KeyBinding(commandID: "edit.redo",           key: "z", modifiers: ["cmd", "shift"]),
        KeyBinding(commandID: "file.export.wav",    key: "e", modifiers: ["cmd"]),
        KeyBinding(commandID: "midi.panic",         key: ".", modifiers: ["cmd"]),
        KeyBinding(commandID: "file.autosave.now",  key: "s", modifiers: ["cmd", "alt"])
    ])

    static let proToolsStyle = KeyBindingSet(name: "Pro Tools", bindings: [
        KeyBinding(commandID: "transport.play-stop", key: "space"),
        KeyBinding(commandID: "edit.undo",           key: "z", modifiers: ["cmd"]),
        KeyBinding(commandID: "edit.redo",           key: "z", modifiers: ["cmd", "shift"]),
        KeyBinding(commandID: "file.export.wav",    key: "b", modifiers: ["cmd"]),
        KeyBinding(commandID: "midi.panic",         key: ".", modifiers: ["cmd"])
    ])

    static let logicStyle = KeyBindingSet(name: "Logic Pro", bindings: [
        KeyBinding(commandID: "transport.play-stop", key: "space"),
        KeyBinding(commandID: "edit.undo",           key: "z", modifiers: ["cmd"]),
        KeyBinding(commandID: "edit.redo",           key: "z", modifiers: ["cmd", "shift"]),
        KeyBinding(commandID: "file.export.wav",    key: "b", modifiers: ["cmd"]),
        KeyBinding(commandID: "midi.panic",         key: ".", modifiers: ["cmd"])
    ])

    public static let allPresets: [KeyBindingSet] = [toooTDefault, proToolsStyle, logicStyle]
}
