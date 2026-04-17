/*
 *  PROJECT ToooT (ToooT_Core)
 *  Automation lanes — time-varying parameter values evaluated per audio frame.
 *
 *  Automation is the foundation for "parameter X changes shape Y over time Z".
 *  Lanes hold a sorted array of (beat, value) points plus a curve type per
 *  segment; evaluation interpolates between adjacent points.
 *
 *  Modes match pro DAWs:
 *    • read  — render follows the recorded lane
 *    • write — UI edits overwrite the lane from the playhead forward
 *    • touch — write while the user is dragging; revert to read when released
 *    • latch — write while dragging; stay at the new value after release
 *    • trim  — offsets existing values (relative edit)
 *
 *  Lanes are referenced by a target parameter ID (e.g. "ch.3.volume", "master.vol",
 *  "plugin.<uuid>.param.<paramID>"). The render path asks `evaluate(at:)` per block.
 */

import Foundation

public enum AutomationCurve: String, Codable, Sendable {
    case linear, stepped, exponential, logarithmic, sCurve
}

public struct AutomationPoint: Codable, Sendable, Hashable {
    public var beat: Double
    public var value: Float
    /// Curve shape from THIS point to the next one.
    public var curveOut: AutomationCurve
    public init(beat: Double, value: Float, curveOut: AutomationCurve = .linear) {
        self.beat = beat; self.value = value; self.curveOut = curveOut
    }
}

public enum AutomationMode: String, Codable, Sendable {
    case read, write, touch, latch, trim
}

public struct AutomationLane: Codable, Sendable, Identifiable {
    public var id: UUID
    public var targetID: String
    public var points: [AutomationPoint]
    public var mode: AutomationMode
    public var enabled: Bool

    public init(targetID: String, points: [AutomationPoint] = [], mode: AutomationMode = .read) {
        self.id = UUID(); self.targetID = targetID
        self.points = points.sorted { $0.beat < $1.beat }
        self.mode = mode
        self.enabled = true
    }

    /// Inserts a point and keeps `points` sorted.
    public mutating func setPoint(beat: Double, value: Float, curveOut: AutomationCurve = .linear) {
        if let idx = points.firstIndex(where: { abs($0.beat - beat) < 1e-6 }) {
            points[idx].value = value; points[idx].curveOut = curveOut
        } else {
            points.append(AutomationPoint(beat: beat, value: value, curveOut: curveOut))
            points.sort { $0.beat < $1.beat }
        }
    }

    /// Evaluates the lane at `beat`. Returns the interpolated value or `nil` if
    /// the lane has no points / is disabled (caller falls back to static param).
    public func evaluate(at beat: Double) -> Float? {
        guard enabled, !points.isEmpty else { return nil }
        if beat <= points[0].beat { return points[0].value }
        if beat >= points.last!.beat { return points.last!.value }
        // Find bracketing points.
        var lo = 0, hi = points.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if points[mid].beat <= beat { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let span = b.beat - a.beat
        let t = span > 0 ? Float((beat - a.beat) / span) : 0
        let shaped: Float
        switch a.curveOut {
        case .linear:      shaped = t
        case .stepped:     shaped = 0   // step at `a`, jump to `b` on arrival — simpler model
        case .exponential: shaped = t * t
        case .logarithmic: shaped = sqrtf(t)
        case .sCurve:      shaped = t * t * (3 - 2 * t)   // smoothstep
        }
        return a.value + (b.value - a.value) * shaped
    }
}

/// A batch of lanes for a project. Stored on PlaybackState / Arrangement.
public final class AutomationBank: @unchecked Sendable, Codable {
    public private(set) var lanes: [String: AutomationLane] = [:]

    public init() {}

    public func upsert(_ lane: AutomationLane) {
        lanes[lane.targetID] = lane
    }

    public func remove(targetID: String) {
        lanes[targetID] = nil
    }

    public func evaluate(targetID: String, at beat: Double) -> Float? {
        lanes[targetID]?.evaluate(at: beat)
    }

    public func exportAsPluginStateData() -> [String: Data] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return ["automation": data]
    }

    public static func importFromPluginStateData(_ states: [String: Data]) -> AutomationBank? {
        guard let data = states["automation"] else { return nil }
        return try? JSONDecoder().decode(AutomationBank.self, from: data)
    }

    enum CodingKeys: String, CodingKey { case lanes }
    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.lanes = try c.decode([String: AutomationLane].self, forKey: .lanes)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lanes, forKey: .lanes)
    }
}
