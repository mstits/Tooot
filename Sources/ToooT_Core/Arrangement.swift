/*
 *  PROJECT ToooT (ToooT_Core)
 *  Linear arrangement model — the "horizontal timeline of clips on tracks" paradigm.
 *
 *  This is the model layer for roadmap item #2. The tracker pattern grid ships
 *  today and remains the primary composition surface; the arrangement view lets
 *  users lay out pattern-blocks, audio clips, and MIDI regions along a linear
 *  timeline (Pro Tools / Logic / Reaper paradigm).
 *
 *  This file is deliberately model-only — no UI, no render integration yet.
 *  Those come in follow-up pushes. What ships here:
 *    • Arrangement + Track + Clip data structures
 *    • Codable serialization (for .mad TOOO chunk)
 *    • Time math helpers (beats ↔ samples ↔ bars/beats/ticks)
 *    • `clipsActive(atBeat:)` query so a future render path can pull active clips
 */

import Foundation

// MARK: - Time

/// One beat at a given BPM. Used everywhere in the arrangement as the canonical time unit.
public struct Beats: Codable, Sendable, Hashable {
    public var value: Double
    public init(_ v: Double) { self.value = v }
    public static let zero = Beats(0)

    public func asSamples(bpm: Int, sampleRate: Double) -> Int {
        Int(value * 60.0 / Double(max(1, bpm)) * sampleRate)
    }
    public static func fromSamples(_ n: Int, bpm: Int, sampleRate: Double) -> Beats {
        Beats(Double(n) / sampleRate * Double(max(1, bpm)) / 60.0)
    }

    public static func + (a: Beats, b: Beats) -> Beats { Beats(a.value + b.value) }
    public static func - (a: Beats, b: Beats) -> Beats { Beats(a.value - b.value) }
    public static func < (a: Beats, b: Beats) -> Bool { a.value < b.value }
    public static func > (a: Beats, b: Beats) -> Bool { a.value > b.value }
}

// MARK: - Clip

public enum ClipKind: String, Codable, Sendable {
    case pattern    // references a tracker pattern
    case audio      // PCM region in the UnifiedSampleBank
    case midi       // raw MIDI sequence
}

/// A single clip on a track. Start is in beats, duration is in beats. Source is
/// kind-dependent — for .pattern a pattern index; for .audio a SampleRegion offset;
/// for .midi an index into an owned MIDI event array.
public struct Clip: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ClipKind
    public var start: Beats
    public var duration: Beats

    /// For .pattern clips: pattern index. For .audio clips: bank offset (Float count).
    /// For .midi clips: index into Track.midiEvents.
    public var sourceIndex: Int
    /// For .audio clips: length in source samples — lets us distinguish the clip's
    /// duration-in-timeline (which can be stretched / shortened via warp) from the
    /// underlying sample length.
    public var sourceLength: Int

    public var fadeInBeats:  Beats
    public var fadeOutBeats: Beats
    public var gainLinear:   Float
    /// Optional playback-rate multiplier applied to audio clips. 1.0 = no stretch.
    /// Time-stretch preserves pitch; use in conjunction with `OfflineDSP.timeStretch`
    /// when you want to bake the warp into the source.
    public var playbackRate: Double
    public var muted: Bool

    public init(kind: ClipKind, name: String = "",
                start: Beats, duration: Beats,
                sourceIndex: Int = 0, sourceLength: Int = 0,
                fadeInBeats: Beats = .zero, fadeOutBeats: Beats = .zero,
                gainLinear: Float = 1.0, playbackRate: Double = 1.0,
                muted: Bool = false) {
        self.id = UUID()
        self.name = name; self.kind = kind
        self.start = start; self.duration = duration
        self.sourceIndex = sourceIndex; self.sourceLength = sourceLength
        self.fadeInBeats = fadeInBeats; self.fadeOutBeats = fadeOutBeats
        self.gainLinear = gainLinear; self.playbackRate = playbackRate
        self.muted = muted
    }

    public var endBeat: Beats { Beats(start.value + duration.value) }

    public func contains(beat: Beats) -> Bool {
        !muted && beat.value >= start.value && beat.value < endBeat.value
    }

    /// Fade envelope at `beat` within the clip — linear in/out, 1.0 in the body.
    public func envelopeAmplitude(at beat: Beats) -> Float {
        guard contains(beat: beat) else { return 0 }
        let intoClip = beat.value - start.value
        let fromEnd  = endBeat.value - beat.value
        var gain = gainLinear
        if fadeInBeats.value > 0 && intoClip < fadeInBeats.value {
            gain *= Float(intoClip / fadeInBeats.value)
        }
        if fadeOutBeats.value > 0 && fromEnd < fadeOutBeats.value {
            gain *= Float(fromEnd / fadeOutBeats.value)
        }
        return gain
    }
}

// MARK: - Track

public struct Track: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var channelIndex: Int   // maps to the existing ToooT channel grid
    public var clips: [Clip]
    public var muted: Bool
    public var soloed: Bool

    public init(name: String, channelIndex: Int) {
        self.id = UUID()
        self.name = name
        self.channelIndex = channelIndex
        self.clips = []
        self.muted = false
        self.soloed = false
    }

    public mutating func add(_ clip: Clip) {
        clips.append(clip)
        clips.sort { $0.start.value < $1.start.value }
    }

    public func clips(activeAt beat: Beats) -> [Clip] {
        guard !muted else { return [] }
        // Binary search could optimize; clips are rarely > 100 so linear is fine.
        return clips.filter { $0.contains(beat: beat) }
    }

    public var totalDuration: Beats {
        let end = clips.map { $0.endBeat.value }.max() ?? 0
        return Beats(end)
    }
}

// MARK: - Arrangement

public final class Arrangement: @unchecked Sendable, Codable {
    public var tracks: [Track]
    public var bpm: Int
    public var timeSignature: (numerator: Int, denominator: Int)
    public var loopStart: Beats?
    public var loopEnd:   Beats?

    enum CodingKeys: String, CodingKey {
        case tracks, bpm, tsNum, tsDen, loopStart, loopEnd
    }

    public init(bpm: Int = 125, tracks: [Track] = [],
                timeSignature: (Int, Int) = (4, 4)) {
        self.bpm = bpm
        self.tracks = tracks
        self.timeSignature = timeSignature
        self.loopStart = nil; self.loopEnd = nil
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tracks     = try c.decode([Track].self, forKey: .tracks)
        self.bpm        = try c.decode(Int.self,      forKey: .bpm)
        let tsN         = try c.decode(Int.self,      forKey: .tsNum)
        let tsD         = try c.decode(Int.self,      forKey: .tsDen)
        self.timeSignature = (tsN, tsD)
        self.loopStart  = try c.decodeIfPresent(Beats.self, forKey: .loopStart)
        self.loopEnd    = try c.decodeIfPresent(Beats.self, forKey: .loopEnd)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(bpm,    forKey: .bpm)
        try c.encode(timeSignature.numerator,   forKey: .tsNum)
        try c.encode(timeSignature.denominator, forKey: .tsDen)
        try c.encodeIfPresent(loopStart, forKey: .loopStart)
        try c.encodeIfPresent(loopEnd,   forKey: .loopEnd)
    }

    // MARK: - Queries

    /// All (track, clip) pairs active at a given playhead beat, honoring solo logic.
    public func activeClips(atBeat beat: Beats) -> [(Track, Clip)] {
        let anySolo = tracks.contains { $0.soloed }
        var out: [(Track, Clip)] = []
        for track in tracks {
            if anySolo && !track.soloed { continue }
            for clip in track.clips(activeAt: beat) {
                out.append((track, clip))
            }
        }
        return out
    }

    public var totalDuration: Beats {
        Beats(tracks.map { $0.totalDuration.value }.max() ?? 0)
    }

    /// Render-path helper: at the given playhead `beat`, returns the
    /// (patternIndex, rowWithinPattern) tuple for the track whose
    /// `channelIndex` matches `ch` — if a pattern clip is active there.
    /// Returns `nil` when no clip is active for that channel, in which
    /// case the engine falls back to its order-list lookup.
    ///
    /// Tracker convention: 64 rows per pattern, 4 rows per beat → 16
    /// beats per pattern. The clip's `start.value` is the project beat
    /// at which the clip begins; `(beat - clip.start) * 4` gives the
    /// row offset within the clip's source pattern, modulo 64 so loops
    /// in long clips wrap.
    public func activePatternRow(forChannel ch: Int, atBeat beat: Double) -> (pattern: Int, row: Int)? {
        let anySolo = tracks.contains { $0.soloed }
        for track in tracks where track.channelIndex == ch {
            if anySolo && !track.soloed { continue }
            if track.muted { continue }
            for clip in track.clips where clip.kind == .pattern {
                guard !clip.muted else { continue }
                if beat >= clip.start.value && beat < clip.start.value + clip.duration.value {
                    let rowOffset = Int(((beat - clip.start.value) * 4.0).rounded(.down)) % 64
                    return (pattern: clip.sourceIndex, row: rowOffset)
                }
            }
        }
        return nil
    }

    // MARK: - Serialization helpers (for .mad TOOO chunk alongside scenes + plugin states)

    public func exportAsPluginStateData() -> [String: Data] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return ["arrangement": data]
    }

    public static func importFromPluginStateData(_ states: [String: Data]) -> Arrangement? {
        guard let data = states["arrangement"] else { return nil }
        return try? JSONDecoder().decode(Arrangement.self, from: data)
    }
}
