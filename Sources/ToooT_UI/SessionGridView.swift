/*
 *  PROJECT ToooT (ToooT_UI)
 *  Session / clip-launch grid view — the Ableton Live paradigm.
 *
 *  Rows = scenes (across all tracks). Columns = tracks. Cells are launchable
 *  clips; clicking one queues it for the next quantized boundary. Scene launch
 *  fires every non-empty cell in that row. Column "stop" clears the playing
 *  clip on that track.
 *
 *  Backed by ToooT_Core.SessionGrid — the model carries all state. This view
 *  is pure presentation + input. Persistence rides through .mad TOOO chunk.
 */

import SwiftUI
import ToooT_Core

@MainActor
public struct SessionGridView: View {
    @Bindable var state: PlaybackState
    @State private var grid: SessionGrid

    @State private var selectedRow: Int = 0
    @State private var selectedCol: Int = 0
    @State private var quantization: LaunchQuantization = .bar

    public init(state: PlaybackState) {
        self.state = state
        self._grid = State(initialValue: Self.loadOrSeed(state: state))
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            body_
        }
        .background(Color.black.opacity(0.95))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("SESSION", systemImage: "square.grid.3x3.fill")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(.orange)
            Text("\(grid.numRows) scenes × \(grid.numCols) tracks")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
            Picker("Quantize", selection: $quantization) {
                ForEach([LaunchQuantization.immediate, .eighth, .quarter, .half, .bar, .twoBar, .fourBar],
                        id: \.self) { q in
                    Text(q.displayLabel).tag(q)
                }
            }
            .pickerStyle(.menu).controlSize(.mini).frame(width: 110)
            Button("Stop All") { stopAll() }.controlSize(.mini)
            Button("Save") { saveIntoState() }.controlSize(.mini)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.black.opacity(0.6))
    }

    // MARK: - Grid body

    private var body_: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    sceneColumn
                    tracksGrid
                }
            }
        }
    }

    private var sceneColumn: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.05))
                .frame(width: 80, height: 24)
                .overlay(Text("Scene").font(.system(size: 9, design: .monospaced))
                                      .foregroundColor(.secondary))
            ForEach(0..<grid.numRows, id: \.self) { row in
                HStack(spacing: 4) {
                    Button {
                        launchScene(row)
                    } label: {
                        Image(systemName: "play.fill").font(.system(size: 9)).foregroundColor(.orange)
                    }.buttonStyle(.plain)
                    Text(grid.sceneNames[row]).font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(width: 80, height: 48, alignment: .leading)
                .background(row % 2 == 0 ? Color.white.opacity(0.03) : .clear)
                .overlay(Rectangle().frame(height: 0.5).foregroundColor(.white.opacity(0.1)),
                         alignment: .bottom)
            }
            Rectangle().fill(.clear).frame(width: 80, height: 32)   // spacer above stop row
        }
    }

    private var tracksGrid: some View {
        VStack(spacing: 0) {
            // Column headers (track names)
            HStack(spacing: 0) {
                ForEach(0..<grid.numCols, id: \.self) { col in
                    Text("Track \(col + 1)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 110, height: 24)
                        .background(Color.white.opacity(0.05))
                }
            }
            // Cell grid
            ForEach(0..<grid.numRows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<grid.numCols, id: \.self) { col in
                        cellView(row: row, col: col)
                    }
                }
            }
            // Per-column stop row
            HStack(spacing: 0) {
                ForEach(0..<grid.numCols, id: \.self) { col in
                    Button { stopColumn(col) } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11)).foregroundColor(.red.opacity(0.7))
                            .frame(width: 110, height: 32)
                            .background(Color.white.opacity(0.04))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func cellView(row: Int, col: Int) -> some View {
        let cell = grid.cell(row: row, col: col) ?? SessionCell()
        let isPending = grid.pendingLaunches[col]?.row == row
        let isPlaying = grid.livePlayback[col] == row
        let hasClip = cell.clip != nil

        return Button {
            if hasClip {
                launch(row: row, col: col)
            } else {
                addClip(row: row, col: col)
            }
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(cellFill(hasClip: hasClip, isPending: isPending, isPlaying: isPlaying))
                    .padding(3)
                if hasClip, let clip = cell.clip {
                    HStack(spacing: 4) {
                        Image(systemName: isPlaying ? "play.fill" : (isPending ? "hourglass" : "circle.fill"))
                            .font(.system(size: 9))
                            .foregroundColor(isPlaying ? .green : (isPending ? .yellow : .white.opacity(0.5)))
                        Text(clip.name.isEmpty ? "Clip" : clip.name)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.leading, 10)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.15))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 110, height: 48)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if hasClip {
                Button("Clear") { grid.clear(row: row, col: col) }
            }
        }
    }

    private func cellFill(hasClip: Bool, isPending: Bool, isPlaying: Bool) -> Color {
        if isPlaying { return Color.green.opacity(0.4) }
        if isPending { return Color.yellow.opacity(0.3) }
        if hasClip   { return Color.blue.opacity(0.25) }
        return Color.white.opacity(0.03)
    }

    // MARK: - Actions

    private func launch(row: Int, col: Int) {
        let nowBeat = Beats(Double(state.currentEngineRow) / 4.0)
        grid.launchCell(row: row, col: col, nowBeat: nowBeat, quant: quantization)
    }

    private func launchScene(_ row: Int) {
        let nowBeat = Beats(Double(state.currentEngineRow) / 4.0)
        grid.launchScene(row, nowBeat: nowBeat, quant: quantization)
    }

    private func stopColumn(_ col: Int) {
        grid.livePlayback[col] = nil
        grid.pendingLaunches[col] = nil
    }

    private func stopAll() {
        grid.livePlayback.removeAll()
        grid.pendingLaunches.removeAll()
    }

    private func addClip(row: Int, col: Int) {
        var cell = SessionCell()
        cell.clip = Clip(kind: .pattern, name: "Clip \(row + 1)-\(col + 1)",
                        start: .zero, duration: Beats(4), sourceIndex: 0)
        grid.setCell(cell, row: row, col: col)
    }

    // MARK: - Persistence

    private func saveIntoState() {
        state.pluginStates.merge(grid.exportAsPluginStateData()) { _, new in new }
        state.showStatus("Session saved — write .mad to persist")
    }

    private static func loadOrSeed(state: PlaybackState) -> SessionGrid {
        if let existing = SessionGrid.importFromPluginStateData(state.pluginStates) {
            return existing
        }
        return SessionGrid(rows: 8, columns: 8)
    }
}

private extension LaunchQuantization {
    var displayLabel: String {
        switch self {
        case .immediate: return "Now"
        case .eighth:    return "1/8"
        case .quarter:   return "1/4"
        case .half:      return "1/2"
        case .bar:       return "1 Bar"
        case .twoBar:    return "2 Bar"
        case .fourBar:   return "4 Bar"
        }
    }
}
