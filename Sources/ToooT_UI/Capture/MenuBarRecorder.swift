import SwiftUI
import ScreenCaptureKit

public struct MenuBarRecorder: View {
    @Bindable var state: AppState
    let toggleRecording: () -> Void
    let refreshWindows: () -> Void

    public init(state: AppState, toggleRecording: @escaping () -> Void, refreshWindows: @escaping () -> Void) {
        self.state = state
        self.toggleRecording = toggleRecording
        self.refreshWindows = refreshWindows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(state.isRecording ? .red : .gray)
                    .frame(width: 8, height: 8)
                Text(state.isRecording ? "Recording Window..." : "Ready to Record")
                    .font(.headline)
                
                if state.isRecording {
                    Text(formatTime(state.elapsedTime))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            if !state.isRecording {
                HStack {
                    Picker("Select Window", selection: $state.selectedWindow) {
                        Text("No Window Selected").tag(nil as SCWindow?)
                        ForEach(state.availableWindows, id: \.self) { window in
                            Text(window.owningApplication?.applicationName ?? "Unknown App")
                                .tag(window as SCWindow?)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Button(action: refreshWindows) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Button(state.isRecording ? "Stop Recording" : "Start Recording") {
                toggleRecording()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!state.isRecording && state.selectedWindow == nil)
            
            Divider()
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 250)
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds) ?? "00:00"
    }
}