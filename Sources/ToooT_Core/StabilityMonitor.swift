/*
 *  PROJECT ToooT (ToooT_Core)
 *  Long-run stability monitor.
 *
 *  Used by the 24-hour soak test: track memory growth, buffer underruns, and
 *  priority-inversion warnings. Cheap to run alongside normal playback — just
 *  a periodic `tick()` that samples process resident memory and render glitches.
 *
 *  This file ships the harness. The 24h run itself happens externally via a
 *  StabilityRunner executable or a `--stability` flag on UATRunner — either
 *  calls `StabilityMonitor.shared.tick()` every few seconds during continuous
 *  playback and checks the report at the end.
 */

import Foundation
import Darwin.Mach

public final class StabilityMonitor: @unchecked Sendable {
    public static let shared = StabilityMonitor()

    public struct Sample: Sendable {
        public let wallClock: Date
        public let residentBytes: UInt64
        public let renderGlitches: UInt64
        public let activeVoices: Int
    }

    public private(set) var samples: [Sample] = []
    public private(set) var renderGlitchCount: UInt64 = 0
    private let lock = NSLock()

    public init() {}

    /// Records one snapshot of process memory + counters. Call every 1-10 s.
    public func tick(activeVoices: Int = 0) {
        let mem = Self.residentMemory()
        lock.lock()
        samples.append(Sample(
            wallClock:      Date(),
            residentBytes:  mem,
            renderGlitches: renderGlitchCount,
            activeVoices:   activeVoices))
        lock.unlock()
    }

    /// Call from the audio thread when a render-block glitch (overrun/dropout) is
    /// detected. Thread-safe atomic increment via a simple lock (not on the
    /// render path's fast loop — only on error detection).
    public func recordGlitch() {
        lock.lock(); renderGlitchCount += 1; lock.unlock()
    }

    public struct Report: Sendable {
        public let durationSeconds: TimeInterval
        public let memoryGrowthBytes: Int64
        public let peakMemoryBytes: UInt64
        public let totalGlitches: UInt64
        public let sampleCount: Int
    }

    public func report() -> Report {
        lock.lock(); defer { lock.unlock() }
        guard let first = samples.first, let last = samples.last else {
            return Report(durationSeconds: 0, memoryGrowthBytes: 0,
                          peakMemoryBytes: 0, totalGlitches: 0, sampleCount: 0)
        }
        let peak = samples.map { $0.residentBytes }.max() ?? 0
        return Report(
            durationSeconds:   last.wallClock.timeIntervalSince(first.wallClock),
            memoryGrowthBytes: Int64(last.residentBytes) - Int64(first.residentBytes),
            peakMemoryBytes:   peak,
            totalGlitches:     renderGlitchCount,
            sampleCount:       samples.count)
    }

    public func reset() {
        lock.lock()
        samples.removeAll()
        renderGlitchCount = 0
        lock.unlock()
    }

    // MARK: - Resident memory (bytes) — Mach task info

    public static func residentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
}
