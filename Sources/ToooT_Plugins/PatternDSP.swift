/*
 *  PROJECT ToooT (ToooT_Plugins)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  Offline Pattern Modifiers (Digital Plugs).
 */

import Foundation
import ToooT_Core

public enum PatternDSP {
    
    /// Note Translate: Shifts the pitch of all notes in the selected range
    public static func noteTranslate(
        snapshot: UnsafeMutablePointer<TrackerEvent>,
        startRow: Int,
        endRow: Int,
        semitones: Float
    ) {
        let ratio = pow(2.0, semitones / 12.0)
        
        for row in startRow...endRow {
            let rowOffset = row * kMaxChannels
            for i in 0..<kMaxChannels {
                let ev = snapshot[rowOffset + i]
                if ev.type == .noteOn {
                    snapshot[rowOffset + i].value1 = ev.value1 * ratio
                }
            }
        }
    }
    
    /// Fade Volume: Interpolates volume commands over a selection
    public static func fadeVolume(
        snapshot: UnsafeMutablePointer<TrackerEvent>,
        startRow: Int,
        endRow: Int,
        startVolume: Float,
        endVolume: Float,
        channel: UInt8? = nil
    ) {
        let rowCount = max(1, endRow - startRow)
        let step = (endVolume - startVolume) / Float(rowCount)
        
        for (i, row) in (startRow...endRow).enumerated() {
            let currentVol = startVolume + (step * Float(i))
            let rowOffset = row * kMaxChannels
            
            if let ch = channel {
                let idx = rowOffset + Int(ch)
                snapshot[idx] = TrackerEvent(type: .setVolume, channel: ch, value1: currentVol)
            } else {
                // Apply to all channels
                for c in 0..<kMaxChannels {
                    let idx = rowOffset + c
                    snapshot[idx] = TrackerEvent(type: .setVolume, channel: UInt8(clamping: c), value1: currentVol)
                }
            }
        }
    }
    
    /// Fade Note: Interpolates pitch over a selection (portamento generation)
    public static func fadeNote(
        snapshot: UnsafeMutablePointer<TrackerEvent>,
        startRow: Int,
        endRow: Int,
        startFrequency: Float,
        endFrequency: Float,
        instrument: UInt8,
        channel: UInt8
    ) {
        let rowCount = max(1, endRow - startRow)
        let step = (endFrequency - startFrequency) / Float(rowCount)
        
        for (i, row) in (startRow...endRow).enumerated() {
            let currentFreq = startFrequency + (step * Float(i))
            let idx = row * kMaxChannels + Int(channel)
            snapshot[idx] = TrackerEvent(type: .noteOn, channel: channel, instrument: instrument, value1: currentFreq, value2: -1.0)
        }
    }
    
    /// Revert: Reverses the sequence of events within a pattern selection
    public static func revert(
        snapshot: UnsafeMutablePointer<TrackerEvent>,
        startRow: Int,
        endRow: Int
    ) {
        guard startRow < endRow else { return }
        let rowCount = endRow - startRow + 1
        
        let tempSnapshot: UnsafeMutablePointer<TrackerEvent> = .allocate(capacity: rowCount * kMaxChannels)
        defer { tempSnapshot.deallocate() }
        
        for row in startRow...endRow {
            let srcOffset = row * kMaxChannels
            let dstOffset = (row - startRow) * kMaxChannels
            for ch in 0..<kMaxChannels {
                tempSnapshot[dstOffset + ch] = snapshot[srcOffset + ch]
            }
        }
        
        for row in startRow...endRow {
            let invertedRow = endRow - (row - startRow)
            let srcOffset = (invertedRow - startRow) * kMaxChannels
            let dstOffset = row * kMaxChannels
            for ch in 0..<kMaxChannels {
                snapshot[dstOffset + ch] = tempSnapshot[srcOffset + ch]
            }
        }
    }
    
    /// Propagate: Copies the very first cell of a selection to fill the entire selection block
    public static func propagate(
        snapshot: UnsafeMutablePointer<TrackerEvent>,
        startRow: Int,
        endRow: Int,
        channel: UInt8? = nil
    ) {
        let sourceRowOffset = startRow * kMaxChannels
        var eventsToPropagate = [TrackerEvent]()
        for ch in 0..<kMaxChannels {
            let ev = snapshot[sourceRowOffset + ch]
            if ev.type != .empty || ev.effectCommand > 0 {
                if channel == nil || ev.channel == UInt8(clamping: ch) {
                    eventsToPropagate.append(ev)
                }
            }
        }
        guard !eventsToPropagate.isEmpty else { return }
        
        for row in startRow...endRow {
            if row == startRow { continue }
            let rowOffset = row * kMaxChannels
            for ev in eventsToPropagate {
                snapshot[rowOffset + Int(ev.channel)] = ev
            }
        }
    }
}
