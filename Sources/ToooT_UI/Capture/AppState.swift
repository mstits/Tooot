import SwiftUI
import ScreenCaptureKit

@MainActor @Observable
public final class AppState {
    public var isRecording: Bool = false
    public var elapsedTime: TimeInterval = 0
    public var availableWindows: [SCWindow] = []
    public var selectedWindow: SCWindow?
    public var showFloatingOverlay: Bool = false
    
    // Timer for the elapsed time readout
    private var timer: Timer?
    
    public init() {}
    
    public func startTimer() {
        elapsedTime = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedTime += 1
            }
        }
    }
    
    public func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}