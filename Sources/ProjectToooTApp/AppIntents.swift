/*
 *  PROJECT ToooT
 *  Shortcuts.app integration via AppIntents.
 *
 *  Three intents: Open Project / Open Last Autosave / New Project. Render +
 *  export are deliberately omitted — they require the engine running, which
 *  isn't a reliable assumption for a background Shortcuts run.
 *
 *  AppIntents are discovered automatically from the app bundle. Users find
 *  them in Shortcuts.app under "ToooT" once the app has launched once.
 */

import AppIntents
import Foundation
import AppKit
import ToooT_UI

// MARK: - Open a project file

public struct OpenToooTProjectIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open ToooT Project"
    public static let description = IntentDescription(
        "Opens a .mad or .mod project file in ToooT.")

    @Parameter(title: "Project File",
               supportedContentTypes: [.data])
    public var file: IntentFile

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        let url = file.fileURL ?? URL(fileURLWithPath: file.filename)
        NSWorkspace.shared.open(url)
        return .result()
    }
}

// MARK: - Open last autosave

public struct OpenLastAutosaveIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Last Autosave"
    public static let description = IntentDescription(
        "Opens the most recent ToooT autosave from the last 24 hours.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let recent = AudioHost.recentAutosaves(maxAgeSeconds: 24 * 3600)
        guard let latest = recent.first else {
            return .result(dialog: "No recent autosaves found.")
        }
        NSWorkspace.shared.open(latest)
        return .result(dialog: "Opening \(latest.lastPathComponent).")
    }
}

// MARK: - New project

public struct NewToooTProjectIntent: AppIntent {
    public static let title: LocalizedStringResource = "New ToooT Project"
    public static let description = IntentDescription(
        "Launches ToooT with a blank project ready to record.")

    public static let openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: NSNotification.Name("NewTrackerDocument"), object: nil)
        return .result()
    }
}

// MARK: - Shortcuts provider — surfaces these in Spotlight + Shortcuts gallery

public struct ToooTShortcutsProvider: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenLastAutosaveIntent(),
            phrases: [
                "Restore the latest \(.applicationName) project",
                "Open last \(.applicationName) autosave"
            ],
            shortTitle: "Open Last Autosave",
            systemImageName: "arrow.uturn.backward.circle")
        AppShortcut(
            intent: NewToooTProjectIntent(),
            phrases: [
                "Start a new \(.applicationName) project",
                "New track in \(.applicationName)"
            ],
            shortTitle: "New Project",
            systemImageName: "plus.square.on.square")
    }
}
