/*
 *  PROJECT ToooT (ToooT_UI)
 *  Starter project templates.
 *
 *  Templates are generated programmatically — not shipped as binary .mad blobs —
 *  so they stay in sync with the schema and diff-readable in git. On first app
 *  launch (or on demand) TemplateManager writes the built-ins to
 *  `~/Library/Application Support/ToooT/templates/<slug>.mad` using MADWriter;
 *  users can add their own by saving any open project there.
 */

import Foundation
import ToooT_Core
import ToooT_IO

public struct TemplateManifest: Identifiable, Sendable {
    public var id: String { slug }
    public let slug:        String   // filename-safe
    public let title:       String
    public let description: String
    public let bpm:         Int
    public let ticksPerRow: Int
    public let numChannels: Int
    /// Builder — populates a fresh TrackerEvent slab of size (kMaxChannels * 64 * 100).
    /// Called on a background task; must not touch UI state.
    public let builder: @Sendable (UnsafeMutablePointer<TrackerEvent>) -> Void
}

public enum TemplateManager {

    /// Public application-support directory for user templates + auto-extracted built-ins.
    public static func templateDirectory() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("ToooT/templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Built-in starter templates.
    public static let builtIns: [TemplateManifest] = [
        .blank,
        .drumStarter,
        .ambientPad,
        .technoBasic
    ]

    /// Writes every built-in to disk if its .mad file is missing. Safe to call on every launch.
    public static func materializeBuiltInsIfMissing() {
        guard let dir = templateDirectory() else { return }
        for t in builtIns {
            let url = dir.appendingPathComponent("\(t.slug).mad")
            if FileManager.default.fileExists(atPath: url.path) { continue }
            write(t, to: url)
        }
    }

    /// Writes a template out as a MAD file using an empty instrument bank.
    public static func write(_ t: TemplateManifest, to url: URL) {
        let slabCount = kMaxChannels * 64 * 100
        let slab = UnsafeMutablePointer<TrackerEvent>.allocate(capacity: slabCount)
        slab.initialize(repeating: .empty, count: slabCount)
        defer { slab.deallocate() }

        t.builder(slab)

        // Seed instrument 1 with a safe default so the template isn't useless on open.
        var inst = Instrument()
        inst.setName("Default")
        inst.addRegion(SampleRegion(offset: 0, length: 0))

        try? MADWriter().write(
            events: slab, eventCount: slabCount,
            instruments: [1: inst],
            orderList: [0],
            songLength: 1,
            sampleBank: nil,
            songTitle: t.title,
            pluginStates: [:],
            to: url
        )
    }

    /// Lists every template in the directory (both built-ins and user-saved).
    public static func listAll() -> [URL] {
        guard let dir = templateDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.nameKey])
        else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "mad" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Built-in builders

public extension TemplateManifest {

    /// Empty tracker — 8 channels, 125 BPM, one blank pattern.
    static let blank = TemplateManifest(
        slug:        "blank",
        title:       "Blank Project",
        description: "Empty 8-channel pattern — start from scratch.",
        bpm:         125,
        ticksPerRow: 6,
        numChannels: 8
    ) { _ in /* nothing to do */ }

    /// Four-on-the-floor kick, Euclidean hi-hat, offbeat snare.
    static let drumStarter = TemplateManifest(
        slug:        "drum-starter",
        title:       "Drum Starter",
        description: "Euclidean kit — 4×4 kick, offset hi-hat, snare on 2 & 4. 128 BPM.",
        bpm:         128,
        ticksPerRow: 6,
        numChannels: 8
    ) { events in
        // Channel 0 = kick on rows 0, 16, 32, 48 (four on the floor).
        for row in stride(from: 0, to: 64, by: 16) {
            events[row * kMaxChannels + 0] = TrackerEvent(
                type: .noteOn, channel: 0, instrument: 1,
                value1: 110.0, value2: 0.9)
        }
        // Channel 1 = hi-hat, Euclidean (7 pulses / 16 steps) repeated.
        let hatPattern = EuclideanGenerator.generate(pulses: 7, steps: 16)
        for row in 0..<64 where hatPattern[row % 16] {
            events[row * kMaxChannels + 1] = TrackerEvent(
                type: .noteOn, channel: 1, instrument: 2,
                value1: 880.0, value2: 0.5)
        }
        // Channel 2 = snare on rows 16 and 48 (beats 2 and 4).
        for row in [16, 48] {
            events[row * kMaxChannels + 2] = TrackerEvent(
                type: .noteOn, channel: 2, instrument: 3,
                value1: 220.0, value2: 0.85)
        }
    }

    /// Two-note ambient pad — long sustain, slow tempo.
    static let ambientPad = TemplateManifest(
        slug:        "ambient-pad",
        title:       "Ambient Pad",
        description: "C–F drone, slow tempo, note holds across the whole pattern.",
        bpm:         78,
        ticksPerRow: 12,
        numChannels: 4
    ) { events in
        // Channel 0 = C3 (130.81 Hz) sustained.
        events[0 * kMaxChannels + 0] = TrackerEvent(
            type: .noteOn, channel: 0, instrument: 1,
            value1: 130.81, value2: 0.7)
        // Channel 1 = F3 (174.61 Hz) sustained.
        events[0 * kMaxChannels + 1] = TrackerEvent(
            type: .noteOn, channel: 1, instrument: 1,
            value1: 174.61, value2: 0.5)
    }

    /// Minimal techno — kick + open hat + bass.
    static let technoBasic = TemplateManifest(
        slug:        "techno-basic",
        title:       "Techno Basic",
        description: "Kick, off-beat open hat, bassline skeleton. 125 BPM.",
        bpm:         125,
        ticksPerRow: 6,
        numChannels: 8
    ) { events in
        for row in stride(from: 0, to: 64, by: 16) {
            // Kick
            events[row * kMaxChannels + 0] = TrackerEvent(
                type: .noteOn, channel: 0, instrument: 1,
                value1: 65.41, value2: 1.0) // C2
            // Offbeat open hat (+ 8 rows)
            events[(row + 8) * kMaxChannels + 1] = TrackerEvent(
                type: .noteOn, channel: 1, instrument: 2,
                value1: 1760.0, value2: 0.55)
        }
        // Bassline: C2 on rows 0, 4, C2 oct-up on 8, G1 on 12.
        let bassPattern: [(row: Int, freq: Float)] = [
            (0, 65.41), (4, 65.41), (8, 130.81), (12, 49.0),
            (16, 65.41), (20, 65.41), (24, 130.81), (28, 49.0),
            (32, 65.41), (36, 65.41), (40, 130.81), (44, 49.0),
            (48, 65.41), (52, 65.41), (56, 130.81), (60, 49.0)
        ]
        for item in bassPattern {
            events[item.row * kMaxChannels + 2] = TrackerEvent(
                type: .noteOn, channel: 2, instrument: 3,
                value1: item.freq, value2: 0.8)
        }
    }
}
