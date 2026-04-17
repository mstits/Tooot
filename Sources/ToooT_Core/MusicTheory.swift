/*
 *  PROJECT ToooT (ToooT_Core)
 *  Music-theory helpers: scales, chord generation, note quantization.
 *
 *  Scales are stored as interval sets (semitones from root). Quantization maps any
 *  incoming frequency (or MIDI note) to the nearest in-scale neighbour — lets the
 *  piano-roll / tracker grid enforce key when the user wants it to.
 */

import Foundation

public enum ScaleSet: String, CaseIterable, Sendable {
    case chromatic
    case major
    case naturalMinor
    case harmonicMinor
    case melodicMinor
    case dorian
    case phrygian
    case lydian
    case mixolydian
    case aeolian
    case locrian
    case pentatonicMajor
    case pentatonicMinor
    case blues
    case wholeTone
    case octatonic          // diminished, semi-tone/whole-tone

    /// Intervals in semitones from the root, modulo 12 (or more for symmetric scales).
    public var intervals: [Int] {
        switch self {
        case .chromatic:         return [0,1,2,3,4,5,6,7,8,9,10,11]
        case .major:             return [0,2,4,5,7,9,11]
        case .naturalMinor, .aeolian: return [0,2,3,5,7,8,10]
        case .harmonicMinor:     return [0,2,3,5,7,8,11]
        case .melodicMinor:      return [0,2,3,5,7,9,11]
        case .dorian:            return [0,2,3,5,7,9,10]
        case .phrygian:          return [0,1,3,5,7,8,10]
        case .lydian:            return [0,2,4,6,7,9,11]
        case .mixolydian:        return [0,2,4,5,7,9,10]
        case .locrian:           return [0,1,3,5,6,8,10]
        case .pentatonicMajor:   return [0,2,4,7,9]
        case .pentatonicMinor:   return [0,3,5,7,10]
        case .blues:             return [0,3,5,6,7,10]
        case .wholeTone:         return [0,2,4,6,8,10]
        case .octatonic:         return [0,1,3,4,6,7,9,10]
        }
    }
}

public enum MusicTheory {

    /// Snaps a MIDI note to the nearest in-scale neighbour.
    /// `rootMIDI` is the scale tonic (e.g. 60 for C4). `scale` holds the interval set.
    public static func quantize(midiNote: Int, rootMIDI: Int, scale: ScaleSet) -> Int {
        if scale == .chromatic { return midiNote }
        let intervals = scale.intervals
        // Find the nearest in-scale note across a ±12-semitone window.
        let octave = (midiNote - rootMIDI) / 12
        let residual = ((midiNote - rootMIDI) % 12 + 12) % 12
        var bestDist = Int.max
        var bestInt = intervals[0]
        for iv in intervals {
            let d = abs(iv - residual)
            let dWrap = abs(iv + 12 - residual)
            let minD = min(d, dWrap)
            if minD < bestDist {
                bestDist = minD
                bestInt = (d <= dWrap) ? iv : iv + 12
            }
        }
        return rootMIDI + octave * 12 + bestInt
    }

    /// Snaps a frequency to the nearest in-scale MIDI note (A4 = 440 Hz reference).
    public static func quantize(frequency: Float, rootMIDI: Int, scale: ScaleSet) -> Float {
        guard frequency > 0 else { return frequency }
        let midi = Int(round(12.0 * log2(frequency / 440.0) + 69.0))
        let snapped = quantize(midiNote: midi, rootMIDI: rootMIDI, scale: scale)
        return 440.0 * pow(2.0, Float(snapped - 69) / 12.0)
    }

    // MARK: - Chord generation

    public enum ChordQuality: String, CaseIterable, Sendable {
        case major, minor, diminished, augmented, sus2, sus4,
             maj7, min7, dom7, m7b5, dim7, maj9, min9, dom9
    }

    /// Returns MIDI notes making up the chord rooted at `rootMIDI`.
    public static func chord(rootMIDI: Int, quality: ChordQuality) -> [Int] {
        let intervals: [Int]
        switch quality {
        case .major:       intervals = [0, 4, 7]
        case .minor:       intervals = [0, 3, 7]
        case .diminished:  intervals = [0, 3, 6]
        case .augmented:   intervals = [0, 4, 8]
        case .sus2:        intervals = [0, 2, 7]
        case .sus4:        intervals = [0, 5, 7]
        case .maj7:        intervals = [0, 4, 7, 11]
        case .min7:        intervals = [0, 3, 7, 10]
        case .dom7:        intervals = [0, 4, 7, 10]
        case .m7b5:        intervals = [0, 3, 6, 10]
        case .dim7:        intervals = [0, 3, 6, 9]
        case .maj9:        intervals = [0, 4, 7, 11, 14]
        case .min9:        intervals = [0, 3, 7, 10, 14]
        case .dom9:        intervals = [0, 4, 7, 10, 14]
        }
        return intervals.map { rootMIDI + $0 }
    }
}
