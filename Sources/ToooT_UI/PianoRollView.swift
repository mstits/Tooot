/*
 *  PROJECT ToooT (ToooT_UI)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  Piano Roll Editor — High-Density MIDI Grid.
 */

import SwiftUI
import ToooT_Core

public struct PianoRollView: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?

    @State private var dragIsErasing: Bool = false
    @State private var dragLastCol: Int = -1
    @State private var dragLastNote: Int = -1

    public init(state: PlaybackState, timeline: Timeline? = nil) {
        self.state = state
        self.timeline = timeline
    }
    
    private let noteHeight: CGFloat = 14.0
    private let kCols: Int = 64

    public var body: some View {
        ZStack {
            StudioTheme.industrialGlow().ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Toolbar for Piano Roll
                HStack {
                    Label("PIANO ROLL", systemImage: "pianokeys").font(.system(size: 10, weight: .black, design: .monospaced)).foregroundColor(.blue)
                    Spacer()
                    HStack(spacing: 12) {
                        Text("Zoom").font(.system(size: 8, weight: .bold)).foregroundColor(.gray)
                        Slider(value: $state.xZoom, in: 1.0...10.0).frame(width: 100).controlSize(.mini)
                    }
                    Divider().frame(height: 12).padding(.horizontal, 8)
                    Text("CH \(state.selectedChannel + 1)").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.gray)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(StudioTheme.glassPanel())
                
                HStack(spacing: 0) {
                    // Vertical Keyboard
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach((0...127).reversed(), id: \.self) { note in
                                PianoKeyView(note: note) { previewNote(note) }
                                    .frame(width: 50, height: noteHeight)
                            }
                        }
                    }
                    .scrollDisabled(true) // Should sync with grid scroll
                    
                    // Grid
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            Canvas { context, size in
                                drawGrid(context: context, size: size)
                                drawNotes(context: context, size: size)
                                drawPlayhead(context: context, size: size)
                            }
                            .frame(width: 1200 * state.xZoom, height: 128 * noteHeight)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { handleDrag($0) }.onEnded { _ in dragLastCol = -1; dragLastNote = -1 })
                        }
                    }
                }
            }
        }
    }
    
    private func handleDrag(_ value: DragGesture.Value) {
        let gridWidth = 1200 * state.xZoom
        let rowWidth = gridWidth / CGFloat(kCols)
        let col = Int(value.location.x / rowWidth).clamped(to: 0...(kCols-1))
        let note = 127 - Int(value.location.y / noteHeight).clamped(to: 0...127)
        
        guard col != dragLastCol || note != dragLastNote else { return }
        let idx = (state.currentPattern * 64 + col) * kMaxChannels + state.selectedChannel
        
        if dragLastCol == -1 {
            dragIsErasing = state.sequencerData.events[idx].type == .noteOn
            state.snapshotForUndo()
        }
        
        dragLastCol = col; dragLastNote = note
        
        if dragIsErasing {
            state.sequencerData.events[idx] = .empty
        } else {
            let freq = Float(440.0 * pow(2.0, (Double(note) - 69.0) / 12.0))
            state.sequencerData.events[idx] = TrackerEvent(type: .noteOn, channel: UInt8(state.selectedChannel), instrument: UInt8(state.selectedInstrument), value1: freq)
            previewNote(note)
        }
        timeline?.publishSnapshot(); state.textureInvalidationTrigger += 1
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        let rowWidth = size.width / CGFloat(kCols)
        for col in 0..<kCols {
            let x = CGFloat(col) * rowWidth
            let isBeat = col % 4 == 0
            context.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(isBeat ? Color.white.opacity(0.15) : Color.white.opacity(0.05)), lineWidth: isBeat ? 1 : 0.5)
        }
        for note in 0...127 {
            let y = CGFloat(127 - note) * noteHeight
            let isBlackKey = [1, 3, 6, 8, 10].contains(note % 12)
            if isBlackKey { context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: noteHeight)), with: .color(Color.white.opacity(0.03))) }
            context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(Color.white.opacity(0.05)), lineWidth: 0.5)
        }
    }
    
    private func drawNotes(context: GraphicsContext, size: CGSize) {
        let rowWidth = size.width / CGFloat(kCols)
        let pat = state.currentPattern; let ch = state.selectedChannel
        for r in 0..<64 {
            let ev = state.sequencerData.events[(pat * 64 + r) * kMaxChannels + ch]
            if ev.type == .noteOn && ev.value1 > 0 {
                let m = Int(round(12.0 * log2(Double(ev.value1) / 440.0) + 69.0)).clamped(to: 0...127)
                let rect = CGRect(x: CGFloat(r) * rowWidth + 1, y: CGFloat(127 - m) * noteHeight + 1, width: rowWidth - 2, height: noteHeight - 2)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(StudioTheme.accent))
                context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(.white.opacity(0.3)), lineWidth: 0.5)
            }
        }
    }
    
    private func drawPlayhead(context: GraphicsContext, size: CGSize) {
        guard state.isPlaying else { return }
        let x = CGFloat(Float(state.currentEngineRow) + state.fractionalRow) * (size.width / CGFloat(kCols))
        context.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(.red), lineWidth: 2)
    }
    
    private func previewNote(_ note: Int) {
        let freq = Float(440.0 * pow(2.0, (Double(note) - 69.0) / 12.0)); let ch = UInt8(clamping: state.selectedChannel)
        _ = timeline?.audioEngine?.eventBuffer.push(TrackerEvent(type: .noteOn, channel: ch, instrument: UInt8(state.selectedInstrument), value1: freq))
        Task { try? await Task.sleep(nanoseconds: 150_000_000); _ = timeline?.audioEngine?.eventBuffer.push(TrackerEvent(type: .noteOff, channel: ch)) }
    }
}

struct PianoKeyView: View {
    let note: Int; let action: () -> Void
    var body: some View {
        let isBlack = [1, 3, 6, 8, 10].contains(note % 12); let isC = (note % 12) == 0
        ZStack(alignment: .trailing) {
            Rectangle().fill(isBlack ? Color(white: 0.1) : Color(white: 0.9))
                .overlay(Rectangle().stroke(Color.black.opacity(0.2), lineWidth: 0.5))
            if isC { Text("C\(note / 12 - 1)").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(isBlack ? .white : .black).padding(.trailing, 4) }
        }
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }
}
