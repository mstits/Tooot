/*
 *  PROJECT ToooT (ToooT_Core)
 *  RecordingTake — a single recorded pass on a channel.
 *
 *  Pro DAWs let users record many takes into stacked lanes per channel,
 *  then comp the best bits across takes into a single composite. This
 *  type is the data layer for that workflow:
 *
 *    • Replace mode: each `start` clears the channel's takes and records
 *      a single take.
 *    • Overdub mode: each pass appends a new take to the channel stack.
 *    • Loop mode: punch-in/punch-out at a region; takes 1..N captured
 *      in successive loops.
 *
 *  Engine playback of layered takes is not yet wired (the audio thread
 *  currently plays the active take only). Take comping UI lives on top
 *  of this storage.
 */

import Foundation

public enum RecordingMode: String, Codable, Sendable, CaseIterable {
    /// Each new pass clears the channel's takes and records one new one.
    case replace
    /// Each pass appends a new take to the channel stack; existing takes
    /// continue to play during the new recording.
    case overdub
    /// Punch-in/punch-out at a predefined region; takes captured in a
    /// loop until the user stops.
    case loop
}

public struct RecordingTake: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var channelIndex: Int
    public var sampleRate: Double
    public var samplesL: [Float]
    public var samplesR: [Float]
    /// Project beat at which this take was triggered. Used by the engine
    /// to align playback against the song timeline.
    public var startBeat: Double
    /// Beat at which recording stopped (or `nil` if still active).
    public var endBeat: Double?
    /// Whether this take is selected as the audible one in the comp lane.
    /// Comping = pick the active region from each take.
    public var isActive: Bool

    public init(name: String, channelIndex: Int, sampleRate: Double,
                startBeat: Double = 0) {
        self.id = UUID()
        self.name = name
        self.channelIndex = channelIndex
        self.sampleRate = sampleRate
        self.samplesL = []
        self.samplesR = []
        self.startBeat = startBeat
        self.endBeat = nil
        self.isActive = true
    }

    public var durationSamples: Int { min(samplesL.count, samplesR.count) }
    public var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(durationSamples) / sampleRate
    }
}

/// Per-channel stack of recorded takes. Decoupled from the live
/// recording buffer (PlaybackState.recordedSamplesL/R) — those hold the
/// in-progress capture; this class accumulates finished takes for
/// later comping/playback.
public final class TakeLane: @unchecked Sendable, Codable {
    public var channelIndex: Int
    public private(set) var takes: [RecordingTake]

    public init(channelIndex: Int) {
        self.channelIndex = channelIndex
        self.takes = []
    }

    public var activeTake: RecordingTake? {
        takes.first { $0.isActive }
    }

    public func addTake(_ take: RecordingTake) {
        // Mark prior takes inactive so the latest is what plays. Comp UI
        // can flip activity per region later.
        for i in 0..<takes.count { takes[i].isActive = false }
        var t = take
        t.isActive = true
        takes.append(t)
    }

    /// Replace mode: drop everything, add the single new take.
    public func replaceWith(_ take: RecordingTake) {
        takes.removeAll()
        var t = take
        t.isActive = true
        takes.append(t)
    }

    /// Marks a take active (and others inactive). Comping can pick a
    /// different take per beat-range later; this is the simple "use this
    /// whole take" toggle.
    public func setActive(takeID: UUID) {
        for i in 0..<takes.count {
            takes[i].isActive = (takes[i].id == takeID)
        }
    }

    public func remove(takeID: UUID) {
        takes.removeAll { $0.id == takeID }
        // Re-activate the most recent if we removed the active one.
        if !takes.contains(where: \.isActive), let last = takes.last {
            setActive(takeID: last.id)
        }
    }
}
