/*
 *  PROJECT ToooT (ToooT_UI)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  Helpers and Standardized Formatting.
 */

import SwiftUI
import ToooT_Core
import AVKit

#if os(macOS)
public struct VideoPlayerView: NSViewRepresentable {
    public let player: AVPlayer
    public init(player: AVPlayer) { self.player = player }
    public func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }
    public func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
#endif

// MARK: - Missing Domain Types

public enum PluginType: String, Identifiable, CaseIterable {
    case amplitude, toneGenerator, echo, fade, depth
    case noteTranslate, fadeNote, fadeVolume, complexFade
    case propagate, revert, crop, crossfade, mix
    case samplingRate, length
    case normalize, invert, silence, backwards, smooth
    case importMIDI, importClassicApp
    case ioAIFF, ioWave, ioXI, ioPAT, ioMINs, ioSys7, ioQuickTime
    public var id: String { rawValue }
}

public struct AutomationPoint: Identifiable, Sendable {
    public let id = UUID()
    public var time:  Double
    public var value: Double
    /// Relative offset of the Bezier control point (0,0 is a straight line to the next point)
    public var controlPoint: CGPoint
    
    public init(time: Double, value: Double, controlPoint: CGPoint = .zero) {
        self.time = time
        self.value = value
        self.controlPoint = controlPoint
    }
}

public struct AutomationLane: Identifiable, Sendable {
    public let id = UUID()
    public var parameter: String
    public var points: [AutomationPoint]
    public init(parameter: String, points: [AutomationPoint] = []) { self.parameter = parameter; self.points = points }
    public func evaluate(at position: Double) -> Double {
        let sorted = points.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return 1.0 }
        if position <= sorted[0].time { return sorted[0].value }
        if position >= sorted.last!.time { return sorted.last!.value }

        for i in 0..<sorted.count - 1 {
            let p1 = sorted[i]
            let p2 = sorted[i+1]
            if position >= p1.time && position <= p2.time {
                let t = (position - p1.time) / (p2.time - p1.time)

                if p1.controlPoint == .zero {
                    // Linear interpolation
                    return p1.value + (p2.value - p1.value) * t
                } else {
                    // Quad Bezier interpolation
                    // B(t) = (1-t)^2 * P1 + 2(1-t)t * CP + t^2 * P2
                    // Here CP is absolute, derived from relative p1.controlPoint
                    let cpY = p1.value + (p2.value - p1.value) * 0.5 + Double(-p1.controlPoint.y / 100.0) // normalized

                    let v = pow(1.0 - t, 2.0) * p1.value + 
                            2.0 * (1.0 - t) * t * cpY + 
                            pow(t, 2.0) * p2.value

                    return v.clamped(to: 0...1.0)
                }
            }
        }
        return 1.0
    }
}

// MARK: - DAW Class Widgets

public struct StudioKnob: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    @State private var lastY: CGFloat = 0
    
    public init(label: String, value: Binding<Float>, range: ClosedRange<Float> = 0...1) {
        self.label = label
        self._value = value
        self.range = range
    }
    
    public var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.5), lineWidth: 4)
                    .frame(width: 32, height: 32)
                
                Circle()
                    .trim(from: 0, to: CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * 0.75)
                    .stroke(StudioTheme.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(135))
                
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 10)
                    .offset(y: -11)
                    .rotationEffect(.degrees(Double((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * 270 - 135))
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let delta = Float(lastY - v.location.y) * 0.005
                    value = (value + delta).clamped(to: range)
                    lastY = v.location.y
                }
                .onEnded { _ in lastY = 0 }
            )
            
            Text(label).font(.system(size: 7, weight: .bold)).foregroundColor(.gray)
        }
    }
}

public struct StudioFader: View {
    @Binding var value: Float
    let isMuted: Bool
    
    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Track
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.5)).frame(width: 4)
                
                // Active Fill
                Group {
                    if isMuted {
                        RoundedRectangle(cornerRadius: 2).fill(Color.red.opacity(0.5))
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(StudioTheme.gradient)
                    }
                }
                .frame(width: 4, height: geo.size.height * CGFloat(value))
                
                // Handle
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: 16, height: 8)
                    .offset(y: -geo.size.height * CGFloat(value) + 4)
                    .shadow(radius: 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                value = Float(1.0 - v.location.y / geo.size.height).clamped(to: 0...1)
            })
        }
    }
}

public struct StudioTheme {
    public static let accent = Color(red: 0.0, green: 0.8, blue: 1.0)
    public static let accentMagenta = Color(red: 1.0, green: 0.1, blue: 0.6)
    public static let gradient = LinearGradient(colors: [accent, accentMagenta], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let surface = Color(white: 0.08)
    public static let surfaceHighlight = Color(white: 0.15)
    public static let background = Color(white: 0.03)
    public static let panelBorder = Color(white: 0.2)
    
    @ViewBuilder
    public static func industrialGlow() -> some View {
        ZStack {
            Color.black
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5, 0.5], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1]
            ], colors: [
                .black, .black, .black,
                .black, Color(red: 0.05, green: 0.1, blue: 0.2), .black,
                .black, .black, .black
            ])
            .opacity(0.6)
        }
    }
    
    @ViewBuilder
    public static func glassPanel() -> some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
            Color.black.opacity(0.4)
        }
    }

    #if os(macOS)
    public static func liquidGlass() -> some View { GlassyBackground() }
    #else
    public static func liquidGlass() -> some View { Color.black.opacity(0.8) }
    #endif
}

// Support for macOS Blur/Materials
public struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

#if os(macOS)
public struct GlassyBackground: NSViewRepresentable {
    public func makeNSView(context: Context) -> NSVisualEffectView { let v = NSVisualEffectView(); v.blendingMode = .withinWindow; v.material = .hudWindow; v.state = .active; return v }
    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#endif

public struct IndustrialButtonStyle: ButtonStyle {
    public var color: Color; public var isActive: Bool
    public init(color: Color = .gray, isActive: Bool = false) { self.color = color; self.isActive = isActive }
    public func makeBody(configuration: Configuration) -> some View { configuration.label.padding(.horizontal, 10).padding(.vertical, 6).background(isActive ? color.opacity(0.3) : (configuration.isPressed ? color.opacity(0.2) : Color.white.opacity(0.05))).foregroundColor(isActive ? color : .white).overlay(RoundedRectangle(cornerRadius: 4).stroke(isActive ? color : Color.white.opacity(0.1), lineWidth: 1)) }
}

public struct MeteringView: View {
    let state: PlaybackState
    public init(state: PlaybackState) { self.state = state }
    public var body: some View { HStack(spacing: 16) { VStack(alignment: .center, spacing: 3) { Text("PEAK").font(.system(size: 7, weight: .heavy, design: .monospaced)).foregroundColor(.gray); VUBar(level: CGFloat(state.peakLevel)).frame(width: 12, height: 30) }; EngineHealthView(state: state).frame(width: 90) }.padding(.horizontal, 14).frame(maxHeight: .infinity) }
}

public struct VUBar: View {
    let level: CGFloat
    public init(level: CGFloat) { self.level = level }
    public var body: some View { GeometryReader { geo in ZStack(alignment: .bottom) { RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.1)); RoundedRectangle(cornerRadius: 2).fill(StudioTheme.accent).frame(height: min(geo.size.height, level * geo.size.height)) } } }
}

public struct EngineHealthView: View {
    let state: PlaybackState
    public init(state: PlaybackState) { self.state = state }
    public var body: some View { VStack(alignment: .leading, spacing: 2) { Text("ENGINE LOAD").font(.system(size: 6, weight: .bold)).foregroundColor(.gray); GeometryReader { geo in ZStack(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.05)); Rectangle().fill(StudioTheme.gradient).frame(width: geo.size.width * CGFloat(state.peakLevel)) } }.frame(height: 4) } }
}

public struct WaveformRenderer: Shape {
    nonisolated(unsafe) let pointer: UnsafePointer<Float>; let count: Int
    public init(pointer: UnsafePointer<Float>, count: Int) { self.pointer = pointer; self.count = count }
    public func path(in rect: CGRect) -> Path {
        var p = Path()
        guard count > 0 else { return p }
        let midY = rect.midY
        p.move(to: .init(x: 0, y: midY))
        
        let step = max(1, count / Int(rect.width))
        for x in 0..<Int(rect.width) {
            let i = x * step
            if i < count {
                let val = CGFloat(pointer[i]) * rect.height * 0.4
                p.addLine(to: .init(x: CGFloat(x), y: midY - val))
            }
        }
        return p
    }
}

public struct DSPButton: View {
    let label: String; let action: () -> Void
    public init(label: String, action: @escaping () -> Void) { self.label = label; self.action = action }
    public var body: some View { Button(label, action: action).font(.system(size: 8, weight: .bold)).buttonStyle(.bordered).controlSize(.mini) }
}

public struct AIButton: View {
    let label: String; let systemImage: String; let action: () -> Void
    public init(label: String, systemImage: String, action: @escaping () -> Void) { self.label = label; self.systemImage = systemImage; self.action = action }
    public var body: some View { Button(action: action) { Label(label, systemImage: systemImage).font(.system(size: 9, weight: .bold)) }.buttonStyle(.bordered) }
}

public struct ToolbarKnob<Control: View>: View {
    let label: String; let value: String; @ViewBuilder let control: () -> Control
    public init(label: String, value: String, @ViewBuilder control: @escaping () -> Control) { self.label = label; self.value = value; self.control = control }
    public var body: some View { VStack(spacing: 2) { Text(label).font(.system(size: 7, weight: .heavy, design: .monospaced)).foregroundColor(.gray); Text(value).font(.system(size: 16, weight: .black, design: .monospaced)).foregroundStyle(StudioTheme.gradient); control() } }
}

public struct ToolbarMetric: View {
    let label: String; let value: String
    public init(label: String, value: String) { self.label = label; self.value = value }
    public var body: some View { VStack(spacing: 2) { Text(label).font(.system(size: 7, weight: .heavy, design: .monospaced)).foregroundColor(.gray); Text(value).font(.system(size: 18, weight: .black, design: .monospaced)).foregroundStyle(StudioTheme.gradient) } }
}

public struct TactileDivider: View {
    let axis: Axis; let totalLength: CGFloat; let onDrag: (CGFloat) -> Void
    @State private var isHovering = false; @State private var previousTranslation: CGFloat = 0
    public enum Axis { case horizontal, vertical }
    public init(axis: Axis, totalLength: CGFloat, onDrag: @escaping (CGFloat) -> Void) { self.axis = axis; self.totalLength = totalLength; self.onDrag = onDrag }
    public var body: some View { Rectangle().fill(isHovering ? Color.gray : Color.black).frame(width: axis == .vertical ? 6 : nil, height: axis == .horizontal ? 6 : nil).onHover { isHovering = $0 }.gesture(DragGesture().onChanged { v in let delta = (axis == .vertical ? v.translation.width : v.translation.height) - previousTranslation; previousTranslation = (axis == .vertical ? v.translation.width : v.translation.height); onDrag(delta) }.onEnded { _ in previousTranslation = 0 }) }
}

public struct TierKnob: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    
    public init(label: String, value: Binding<Float>, range: ClosedRange<Float> = 0...1) {
        self.label = label
        self._value = value
        self.range = range
    }
    
    public var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(.gray).frame(width: 80, alignment: .leading)
            Slider(value: $value, in: range).tint(StudioTheme.accent).controlSize(.mini)
            Text("\(Int(value * 100))%").font(.system(size: 8, design: .monospaced)).foregroundColor(.gray).frame(width: 35, alignment: .trailing)
        }
    }
}

public struct StudioSettingsView: View {
    public init() {}
    public var body: some View { VStack { Text("Studio Settings").font(.headline); Text("Configuration options coming soon.").foregroundColor(.gray) }.padding() }
}


