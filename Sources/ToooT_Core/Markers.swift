/*
 *  PROJECT ToooT (ToooT_Core)
 *  Markers, cue points, and time-signature changes.
 *
 *  Markers are named time-position labels users drop in the timeline for
 *  navigation ("Verse", "Drop", "Bridge"). Time signatures are scoped
 *  changes (4/4 → 6/8 → 4/4) that affect beat-to-bar math.
 *
 *  Storage only — engine consumption (jumping playhead via marker, bar
 *  boundary recalculation under time-sig change) lands separately.
 */

import Foundation

public struct Marker: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var beat: Double
    public var color: String?    // hex like "#ff8800", optional

    public init(name: String, beat: Double, color: String? = nil) {
        self.id = UUID()
        self.name = name
        self.beat = beat
        self.color = color
    }
}

public struct TimeSignatureChange: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    /// Beat at which this signature starts. Always 0 for the song's initial
    /// signature; later changes give the bar-boundary anchor.
    public var beat: Double
    public var numerator: Int
    public var denominator: Int

    public init(beat: Double, numerator: Int, denominator: Int) {
        self.id = UUID()
        self.beat = beat
        self.numerator = numerator
        self.denominator = denominator
    }
}

/// Project-level container for markers + time signatures. Persisted into
/// the `.mad` `TOOO` chunk via the same pluginStates merge that scenes use.
public final class TimingMap: @unchecked Sendable, Codable {
    public var markers: [Marker]
    public var timeSignatures: [TimeSignatureChange]

    /// Default: 4/4 from beat 0, no markers.
    public init() {
        self.markers = []
        self.timeSignatures = [TimeSignatureChange(beat: 0, numerator: 4, denominator: 4)]
    }

    /// Inserts a marker, keeping the list sorted by beat.
    public func addMarker(_ marker: Marker) {
        markers.append(marker)
        markers.sort { $0.beat < $1.beat }
    }

    public func removeMarker(id: UUID) {
        markers.removeAll { $0.id == id }
    }

    /// Finds the marker with the closest matching name (case-insensitive
    /// exact match takes priority; falls back to nil).
    public func marker(named name: String) -> Marker? {
        markers.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Returns the active time signature at `beat` — the most recent
    /// signature change at or before `beat`. Always returns *something*
    /// because the first entry is always `beat: 0`.
    public func timeSignature(at beat: Double) -> TimeSignatureChange {
        var current = timeSignatures.first!
        for tsc in timeSignatures where tsc.beat <= beat {
            current = tsc
        }
        return current
    }

    public func setTimeSignature(at beat: Double, numerator: Int, denominator: Int) {
        if let i = timeSignatures.firstIndex(where: { abs($0.beat - beat) < 1e-6 }) {
            timeSignatures[i].numerator = numerator
            timeSignatures[i].denominator = denominator
        } else {
            timeSignatures.append(TimeSignatureChange(beat: beat,
                                                      numerator: numerator,
                                                      denominator: denominator))
            timeSignatures.sort { $0.beat < $1.beat }
        }
    }

    /// Serializes for the `.mad` `TOOO` chunk. Mirrors
    /// `SceneBank.exportAsPluginStateData`.
    public func exportAsPluginStateData() -> [String: Data] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return ["timingMap": data]
    }

    public static func importFromPluginStateData(_ states: [String: Data]) -> TimingMap? {
        guard let data = states["timingMap"] else { return nil }
        return try? JSONDecoder().decode(TimingMap.self, from: data)
    }
}
