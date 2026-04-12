/*
 *  PROJECT ToooT (ToooT_UI)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 */

import SwiftUI
import ToooT_Core

private enum EnvType: Int, CaseIterable, Identifiable {
    case volume = 0, panning, pitch
    var id: Int { rawValue }
    var label: String { ["VOLUME", "PANNING", "PITCH"][rawValue] }
    var color: Color { [Color(red:0,green:0.85,blue:1), Color(red:0.3,green:1,blue:0.4), Color(red:1,green:0.55,blue:0)][rawValue] }
    var minLabel: String { ["0%", "L", "−2st"][rawValue] }
    var maxLabel: String { ["100%", "R", "+2st"][rawValue] }
    var midLabel: String { ["50%", "C", " 0st"][rawValue] }
    var icon: String { ["waveform", "slider.horizontal.3", "tuningfork"][rawValue] }
}

@MainActor
public struct EnvelopeEditorView: View {
    @Bindable var state: PlaybackState; let timeline: Timeline?
    @State private var envType: EnvType = .volume
    @State private var dragIndex: Int? = nil
    private let pad: CGFloat = 22
    public init(state: PlaybackState, timeline: Timeline?) { self.state = state; self.timeline = timeline }

    public var body: some View {
        let _ = state.mixerGeneration
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            if state.instruments[state.selectedInstrument] == nil { emptyState }
            else { canvasStack; bottomBar }
        }.padding(.horizontal)
    }

    private var headerRow: some View {
        HStack {
            Text("ENVELOPE").font(.system(size: 11, weight: .black, design: .monospaced)).foregroundStyle(StudioTheme.gradient)
            Spacer()
            ForEach(EnvType.allCases) { t in
                Button(action: { envType = t }) {
                    Text(t.label).font(.system(size: 9, weight: .bold)).padding(5)
                        .background(envType == t ? t.color.opacity(0.2) : Color.clear).cornerRadius(4)
                }.buttonStyle(.plain)
            }
            Toggle("ON", isOn: enabledBinding).toggleStyle(.button).controlSize(.small)
        }
    }

    private var emptyState: some View { RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.3)).frame(height: 220).overlay(Text("Select an instrument")) }

    private func pointPosition(for pt: EnvelopePoint, w: CGFloat, h: CGFloat, maxP: CGFloat) -> CGPoint {
        let safeW = max(1.0, w - 2 * pad)
        let safeH = max(1.0, h - 2 * pad)
        let x = pad + (CGFloat(pt.pos) / maxP) * safeW
        let y = pad + (1.0 - (CGFloat(pt.val) / 64.0)) * safeH
        return CGPoint(x: x, y: y)
    }

    private var canvasStack: some View {
        HStack(spacing: 8) {
            // Y-axis labels
            VStack {
                Text(envType.maxLabel).font(.system(size: 8, design: .monospaced))
                Spacer()
                Text(envType.midLabel).font(.system(size: 8, design: .monospaced))
                Spacer()
                Text(envType.minLabel).font(.system(size: 8, design: .monospaced))
            }.frame(height: 220).foregroundColor(.gray)

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let env = currentPoints
                let maxP = CGFloat(max(100, env.map { $0.pos }.max() ?? 100))
                
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.6))
                    
                    // Grid lines
                    Path { path in
                        for i in 1..<4 {
                            let y = CGFloat(i) * h / 4.0
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: w, y: y))
                        }
                    }.stroke(Color.white.opacity(0.05), lineWidth: 1)

                    Path { path in
                        for (i, pt) in env.enumerated() {
                            let p = pointPosition(for: pt, w: w, h: h, maxP: maxP)
                            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        }
                    }.stroke(envType.color, lineWidth: 2)
                    
                    ForEach(Array(env.enumerated()), id: \.offset) { idx, pt in
                        Circle().fill(envType.color).frame(width: 12, height: 12)
                            .position(pointPosition(for: pt, w: w, h: h, maxP: maxP))
                            .gesture(DragGesture().onChanged { v in movePoint(idx, to: v.location, w: w, h: h, maxP: maxP) })
                            .contextMenu {
                                Button(role: .destructive) {
                                    deletePoint(idx)
                                } label: {
                                    Label("Delete Point", systemImage: "trash")
                                }
                            }
                    }
                }
                .onTapGesture { loc in
                    addPointAt(loc, w: w, h: h, maxP: maxP)
                }
            }.frame(height: 220)
        }
    }

    private var bottomBar: some View {
        HStack {
            Button("Reset") { resetEnvelope() }.font(.system(size: 10, weight: .bold)).buttonStyle(.bordered)
            Spacer()
            Button("Add Point") { addPoint() }.font(.system(size: 10, weight: .bold)).buttonStyle(.bordered)
        }
    }

    private var currentPoints: [EnvelopePoint] {
        guard let inst = state.instruments[state.selectedInstrument] else { return [] }
        let env = (envType == .volume ? inst.volumeEnvelope : (envType == .panning ? inst.panningEnvelope : inst.pitchEnvelope))
        var pts: [EnvelopePoint] = []
        env.withUnsafeBuffer { buf in pts = Array(buf) }
        return pts
    }

    private func movePoint(_ idx: Int, to loc: CGPoint, w: CGFloat, h: CGFloat, maxP: CGFloat) {
        guard var inst = state.instruments[state.selectedInstrument] else { return }
        var pts = currentPoints; guard idx < pts.count else { return }
        let safeW = max(1.0, w - 2 * pad)
        let safeH = max(1.0, h - 2 * pad)
        let newPos = Int16(((loc.x - pad) / safeW * maxP).clamped(to: 0...maxP))
        let newVal = Int16(((1 - (loc.y - pad) / safeH) * 64).clamped(to: 0...64))
        pts[idx] = EnvelopePoint(pos: newPos, val: newVal)
        setEnv(&inst, pts); state.instruments[state.selectedInstrument] = inst; timeline?.publishSnapshot()
    }

    private func addPoint() {
        guard var inst = state.instruments[state.selectedInstrument] else { return }
        var pts = currentPoints
        // Place new point just past the last existing point, or at 50 if empty.
        let lastPos = pts.map { $0.pos }.max().map { Int16(min(Int($0) + 10, 127)) } ?? 50
        pts.append(EnvelopePoint(pos: lastPos, val: 64)); pts.sort { $0.pos < $1.pos }
        setEnv(&inst, pts); state.instruments[state.selectedInstrument] = inst; timeline?.publishSnapshot()
    }

    private func addPointAt(_ loc: CGPoint, w: CGFloat, h: CGFloat, maxP: CGFloat) {
        guard var inst = state.instruments[state.selectedInstrument] else { return }
        let safeW = max(1.0, w - 2 * pad)
        let safeH = max(1.0, h - 2 * pad)
        // Ignore clicks inside an existing point's hit radius (14 pt)
        let pts = currentPoints
        for pt in pts {
            let p = pointPosition(for: pt, w: w, h: h, maxP: maxP)
            if hypot(loc.x - p.x, loc.y - p.y) < 14 { return }
        }
        let newPos = Int16(((loc.x - pad) / safeW * maxP).clamped(to: 0...maxP))
        let newVal = Int16(((1 - (loc.y - pad) / safeH) * 64).clamped(to: 0...64))
        var newPts = pts; newPts.append(EnvelopePoint(pos: newPos, val: newVal)); newPts.sort { $0.pos < $1.pos }
        setEnv(&inst, newPts); state.instruments[state.selectedInstrument] = inst; timeline?.publishSnapshot()
    }

    private func deletePoint(_ idx: Int) {
        guard var inst = state.instruments[state.selectedInstrument] else { return }
        var pts = currentPoints
        guard pts.count > 2 else { return }  // Keep at least 2 points for a valid envelope
        pts.remove(at: idx)
        setEnv(&inst, pts); state.instruments[state.selectedInstrument] = inst; timeline?.publishSnapshot()
    }

    private func resetEnvelope() {
        guard var inst = state.instruments[state.selectedInstrument] else { return }
        setEnv(&inst, [EnvelopePoint(pos: 0, val: 64), EnvelopePoint(pos: 100, val: 64)])
        state.instruments[state.selectedInstrument] = inst; timeline?.publishSnapshot()
    }

    private func setEnv(_ inst: inout Instrument, _ pts: [EnvelopePoint]) {
        let fe = FixedEnvelope(pts)
        if envType == .volume { inst.volumeEnvelope = fe }
        else if envType == .panning { inst.panningEnvelope = fe }
        else { inst.pitchEnvelope = fe }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { state.isEnvelopeEnabled(type: envType.rawValue, instrument: state.selectedInstrument) },
            set: { enabled in
                if enabled {
                    if var inst = state.instruments[state.selectedInstrument] {
                        let env = (envType == .volume ? inst.volumeEnvelope : (envType == .panning ? inst.panningEnvelope : inst.pitchEnvelope))
                        if env.isEmpty {
                            setEnv(&inst, [EnvelopePoint(pos: 0, val: 64), EnvelopePoint(pos: 100, val: 64)])
                            state.instruments[state.selectedInstrument] = inst
                        }
                    }
                }
                state.setEnvelopeEnabled(enabled, type: envType.rawValue, instrument: state.selectedInstrument)
                timeline?.publishSnapshot()
            }
        )
    }
}


