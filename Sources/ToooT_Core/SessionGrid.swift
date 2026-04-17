/*
 *  PROJECT ToooT (ToooT_Core)
 *  Session / clip-launch grid — Ableton Live paradigm.
 *
 *  Grid of clip slots. Each row = a scene (across all tracks). Each cell = a
 *  launchable clip. Launches are quantized to the next bar or beat boundary.
 *
 *  Model only — UI comes later. Integration with the audio engine: on each bar,
 *  the sequencer checks `SessionGrid.pendingLaunchCell(forTrack:)` and if set
 *  makes that cell the live playback source.
 *
 *  The session grid coexists with the linear arrangement — they're two views of
 *  the same underlying clip material. A clip launched from the grid can be
 *  captured into the arrangement via `Arrangement.captureLive(session:)`.
 */

import Foundation

public struct SessionCell: Codable, Sendable, Identifiable {
    public var id: UUID
    public var clip: Clip?                    // nil = empty slot
    public var followAction: FollowAction

    public init(clip: Clip? = nil, followAction: FollowAction = .stop) {
        self.id = UUID(); self.clip = clip; self.followAction = followAction
    }
}

/// After a clip finishes playing, what does the slot do?
public enum FollowAction: String, Codable, Sendable {
    case stop         // stop; slot becomes idle
    case loop         // retrigger the same clip
    case nextScene    // launch the clip in the row below
    case prevScene    // launch the clip in the row above
    case random       // random non-empty cell in this column
}

public enum LaunchQuantization: String, Codable, Sendable {
    case immediate    // on the next audio buffer
    case eighth       // on the next 1/8 note
    case quarter      // on the next beat
    case half         // on the next half-note
    case bar          // on the next bar
    case twoBar       // every 2 bars
    case fourBar      // every 4 bars
}

public final class SessionGrid: @unchecked Sendable, Codable {
    /// 2D grid: `cells[rowIndex][columnIndex]` where row = scene, column = track.
    public private(set) var cells: [[SessionCell]]
    public var sceneNames: [String]
    public var defaultQuantization: LaunchQuantization

    enum CodingKeys: String, CodingKey { case cells, sceneNames, defaultQuantization }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.cells               = try c.decode([[SessionCell]].self, forKey: .cells)
        self.sceneNames          = try c.decode([String].self,         forKey: .sceneNames)
        self.defaultQuantization = try c.decode(LaunchQuantization.self, forKey: .defaultQuantization)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cells,               forKey: .cells)
        try c.encode(sceneNames,          forKey: .sceneNames)
        try c.encode(defaultQuantization, forKey: .defaultQuantization)
    }

    public init(rows: Int = 8, columns: Int = 8) {
        self.cells = (0..<rows).map { _ in
            (0..<columns).map { _ in SessionCell() }
        }
        self.sceneNames = (0..<rows).map { "Scene \($0 + 1)" }
        self.defaultQuantization = .bar
    }

    public var numRows: Int { cells.count }
    public var numCols: Int { cells.first?.count ?? 0 }

    public func cell(row: Int, col: Int) -> SessionCell? {
        guard row >= 0, row < cells.count, col >= 0, col < cells[row].count else { return nil }
        return cells[row][col]
    }

    public func setCell(_ cell: SessionCell, row: Int, col: Int) {
        guard row >= 0, row < cells.count, col >= 0, col < cells[row].count else { return }
        cells[row][col] = cell
    }

    public func clear(row: Int, col: Int) {
        setCell(SessionCell(), row: row, col: col)
    }

    // MARK: - Launch scheduling

    /// Pending launches per column. `pendingLaunches[column]` = (row, atBeat).
    /// Set by the UI via `launchCell(row:col:atBeat:)`; consumed by the audio-engine
    /// integration when the playhead reaches the beat boundary.
    public var pendingLaunches: [Int: (row: Int, atBeat: Beats)] = [:]
    public var livePlayback:    [Int: Int] = [:]   // [column: row] of currently-playing cell

    /// Quantize `nowBeat` up to the next boundary for `quant`.
    public static func nextBoundary(after nowBeat: Beats, quant: LaunchQuantization) -> Beats {
        let step: Double
        switch quant {
        case .immediate: return nowBeat
        case .eighth:    step = 0.5
        case .quarter:   step = 1
        case .half:      step = 2
        case .bar:       step = 4
        case .twoBar:    step = 8
        case .fourBar:   step = 16
        }
        let snapped = ceil(nowBeat.value / step) * step
        return Beats(snapped)
    }

    public func launchCell(row: Int, col: Int, nowBeat: Beats,
                           quant: LaunchQuantization? = nil) {
        guard cell(row: row, col: col)?.clip != nil else { return }
        let q = quant ?? defaultQuantization
        pendingLaunches[col] = (row, SessionGrid.nextBoundary(after: nowBeat, quant: q))
    }

    public func launchScene(_ row: Int, nowBeat: Beats,
                            quant: LaunchQuantization? = nil) {
        for col in 0..<numCols {
            if cell(row: row, col: col)?.clip != nil {
                launchCell(row: row, col: col, nowBeat: nowBeat, quant: quant)
            }
        }
    }

    /// Called from the audio engine on each bar boundary. Consumes pending launches
    /// whose beat ≤ nowBeat and moves them into livePlayback. Returns columns that
    /// transitioned — caller triggers their clips.
    public func advanceLaunches(nowBeat: Beats) -> [(col: Int, row: Int)] {
        var transitions: [(col: Int, row: Int)] = []
        for (col, pending) in pendingLaunches where pending.atBeat.value <= nowBeat.value {
            livePlayback[col] = pending.row
            transitions.append((col: col, row: pending.row))
        }
        for (col, pending) in pendingLaunches where pending.atBeat.value <= nowBeat.value {
            pendingLaunches[col] = nil
            _ = pending
        }
        return transitions
    }

    // MARK: - Serialization for .mad TOOO

    public func exportAsPluginStateData() -> [String: Data] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return ["session": data]
    }

    public static func importFromPluginStateData(_ states: [String: Data]) -> SessionGrid? {
        guard let data = states["session"] else { return nil }
        return try? JSONDecoder().decode(SessionGrid.self, from: data)
    }
}
