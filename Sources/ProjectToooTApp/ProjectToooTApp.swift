/*
 *  PROJECT ToooT
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  macOS 16 Tabbed Document Architecture.
 */

import SwiftUI
import ToooT_UI
import ToooT_Core
@preconcurrency import ScreenCaptureKit
import os.log

private let appLog = Logger(subsystem: "com.apple.ProjectToooT", category: "App")

@main
struct ProjectToooTApp: App {
    
    // Global settings for the 2026 Studio Environment
    @State private var globalTheme = "CarbonDeep"
    @State private var captureState = AppState()
    @State private var hotkeyHandler: GlobalHotkeyHandler?

    init() {
        #if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }

    var body: some Scene {
        // Multi-Window Support: Each song is a discrete instance
        WindowGroup(for: URL.self) { $url in
            TrackerAppView(documentURL: url)
                .frame(minWidth: 1000, minHeight: 700)
                .onAppear {
                    if hotkeyHandler == nil {
                        hotkeyHandler = GlobalHotkeyHandler { Task { @MainActor in toggleRecording() } }
                    }
                    #if os(macOS)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                    #endif
                }
        }
        .windowStyle(.hiddenTitleBar)
        
        MenuBarExtra {
            MenuBarRecorder(state: captureState, toggleRecording: toggleRecording, refreshWindows: refreshWindows)
        } label: {
            Image(systemName: captureState.isRecording ? "record.circle.fill" : "record.circle")
                .foregroundColor(captureState.isRecording ? .red : .primary)
        }
        .menuBarExtraStyle(.window)
        
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Tracker Document") {
                    NotificationCenter.default.post(name: NSNotification.Name("NewTrackerDocument"), object: nil)
                }.keyboardShortcut("n", modifiers: .command)
                Button("Open Document...") {
                    NotificationCenter.default.post(name: NSNotification.Name("LoadModFileURL"), object: nil)
                }.keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Filter Plugs") {
                Button("Amplitude") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "amplitude") }
                Button("Backwards") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "backwards") }
                Button("Crop") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "crop") }
                Button("Crossfade") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "crossfade") }
                Button("Depth") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "depth") }
                Button("Echo") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "echo") }
                Button("Fade") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "fade") }
                Button("Invert") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "invert") }
                Button("Length") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "length") }
                Button("Mix") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "mix") }
                Button("Normalize") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "normalize") }
                Button("Sampling Rate") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "samplingRate") }
                Button("Silence") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "silence") }
                Button("Smooth") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "smooth") }
                Button("Tone Generator") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "toneGenerator") }
            }
            CommandMenu("Digital Plugs") {
                Button("Complex Fade") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "complexFade") }
                Button("Fade Note") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "fadeNote") }
                Button("Fade Volume") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "fadeVolume") }
                Button("Note Translate") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "noteTranslate") }
                Button("Propagate") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "propagate") }
                Button("Revert") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "revert") }
            }
            CommandMenu("I/O Plugs") {
                Button("Import MIDI") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "importMIDI") }
                Button("Import Classic App") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "importClassicApp") }
                Divider()
                Button("AIFF Bridge") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "ioAIFF") }
                Button("WAVE Bridge") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "ioWave") }
                Button("FastTracker XI") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "ioXI") }
                Button("Gravis PAT") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "ioPAT") }
                Button("LegacyTracker MINs") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "ioMINs") }
                Button("Sys7 Sound") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "ioSys7") }
                Button("QuickTime") { NotificationCenter.default.post(name: NSNotification.Name("OpenPluginDialog"), object: "ioQuickTime") }
            }
            CommandMenu("Neural AI") {
                Button("Bassline Suggestion") {
                    NotificationCenter.default.post(name: NSNotification.Name("NeuralGenerate"), object: "bassline")
                }.keyboardShortcut("1", modifiers: [.command, .shift])
                Button("Harmony Analysis") {
                    NotificationCenter.default.post(name: NSNotification.Name("NeuralGenerate"), object: "harmony")
                }.keyboardShortcut("2", modifiers: [.command, .shift])
                Button("Drum Re-Phase") {
                    NotificationCenter.default.post(name: NSNotification.Name("NeuralGenerate"), object: "drums")
                }.keyboardShortcut("3", modifiers: [.command, .shift])
                Button("Neural Pattern Gen") {
                    NotificationCenter.default.post(name: NSNotification.Name("NeuralGenerate"), object: "lsystem")
                }.keyboardShortcut("4", modifiers: [.command, .shift])
            }
            CommandMenu("AUv3 Inserts") {
                Button("Toggle Stereo Wide") {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleStereoWide"), object: nil)
                }
                Button("Toggle Pro Reverb") {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleReverb"), object: nil)
                }
            }
            CommandMenu("Transport") {
                Button("Play/Stop") {
                    NotificationCenter.default.post(name: NSNotification.Name("TransportToggle"), object: nil)
                }.keyboardShortcut(.space, modifiers: [])
                Button("Stop") {
                    NotificationCenter.default.post(name: NSNotification.Name("TransportStop"), object: nil)
                }.keyboardShortcut(".", modifiers: .command)
            }
        }
        
        // Settings Panel
        Window("Studio Settings", id: "settings") {
            StudioSettingsView()
                .frame(minWidth: 520, minHeight: 420)
        }
        .windowResizability(.contentSize)
    }
    
    // MARK: - Capture Controls
    
    @MainActor
    private func toggleRecording() {
        if captureState.isRecording {
            stopCapture()
        } else {
            startCapture()
        }
    }
    
    @MainActor
    private func startCapture() {
        guard let window = captureState.selectedWindow else { return }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("ToooT_Capture_\(Date().timeIntervalSince1970).mp4")
        Task {
            do {
                try await RecorderManager.shared.startCapture(window: window, outputURL: fileURL)
                captureState.isRecording = true
                captureState.startTimer()
            } catch {
                appLog.error("Capture start failed: \(error)")
            }
        }
    }

    @MainActor
    private func stopCapture() {
        Task {
            do {
                try await RecorderManager.shared.stopCapture()
                captureState.isRecording = false
                captureState.stopTimer()
            } catch {
                appLog.error("Capture stop failed: \(error)")
            }
        }
    }
    
    private func refreshWindows() {
        Task {
            let content = try? await SCShareableContent.current
            await MainActor.run {
                captureState.availableWindows = content?.windows.filter { 
                    $0.isOnScreen && $0.title != nil && !$0.title!.isEmpty 
                } ?? []
            }
        }
    }
}
