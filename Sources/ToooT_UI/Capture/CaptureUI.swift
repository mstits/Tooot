import SwiftUI
import AppKit

public final class CaptureOverlayPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.hasShadow = true
        self.contentView = contentView
        
        // Position at bottom center by default
        if let screen = NSScreen.main {
            let x = (screen.frame.width - 64) / 2
            let y = 100.0
            self.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

public struct OverlayControlView: View {
    let stopAction: () -> Void
    
    public var body: some View {
        Button(action: stopAction) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 54, height: 54)
                    .overlay(Circle().stroke(.red.opacity(0.5), lineWidth: 2))
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(.red)
                    .frame(width: 18, height: 18)
            }
        }
        .buttonStyle(.plain)
    }
}

public final class GlobalHotkeyHandler {
    private var monitor: Any?
    
    public init(toggleAction: @escaping () -> Void) {
        // Global monitor for Cmd+Shift+R
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains([.command, .shift]), event.keyCode == 15 { // 15 is 'R'
                toggleAction()
            }
        }
    }
    
    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}