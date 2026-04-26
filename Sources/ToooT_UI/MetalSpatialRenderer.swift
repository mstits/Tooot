/*
 *  PROJECT ToooT (ToooT_UI)
 *  Spatial Audio Workbench — top-down listener view + draggable channel sources.
 *
 *  Replaces the previous mesh-shader Metal renderer, which silently failed on
 *  base M1 hardware (Mesh shaders need Apple GPU family 7+) and rendered as a
 *  black screen everywhere else due to `clearColor` alpha = 0.
 *
 *  This view uses SwiftUI Canvas — works on every macOS-supported GPU, has
 *  smooth interactivity, and gives users an obvious mental model: drop
 *  channels around the listener; angle = panning, distance = audio
 *  distance, volume = dot size.
 *
 *  Per-channel positions live on `PlaybackState.channelPositions`; when the
 *  audio host wires `node.spatialPush`, those positions are consumed by
 *  `SpatialManager` (PHASE 3D engine).
 */

import SwiftUI
import ToooT_Core

#if os(macOS)
public struct MetalSpatialView: View {
    @Bindable var state: PlaybackState
    @State private var dragChannel: Int? = nil
    @State private var hoverChannel: Int? = nil

    /// World extent in metres around the listener. Channel positions are
    /// stored as `SIMD3<Float>(x, y, z)` in metres; we render the XZ plane
    /// (top-down) — height (Y) is ignored in this view.
    private let extent: CGFloat = 8.0

    public init(state: PlaybackState) { self.state = state }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                background

                Canvas { ctx, size in
                    drawGrid(in: ctx, size: size)
                    drawListener(in: ctx, size: size)
                    drawChannels(in: ctx, size: size)
                    drawHoverInfo(in: ctx, size: size)
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in handleDrag(at: value.location, size: geo.size) }
                        .onEnded { _ in dragChannel = nil }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        hoverChannel = closestChannel(to: p, in: geo.size, threshold: 16)
                    case .ended:
                        hoverChannel = nil
                    }
                }

                legend
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Layers

    private var background: some View {
        LinearGradient(
            colors: [Color(red: 0.04, green: 0.06, blue: 0.10),
                     Color(red: 0.02, green: 0.03, blue: 0.06)],
            startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SPATIAL AUDIO")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(StudioTheme.gradient)
            Text("Drag channel dots — angle pans L↔R, distance attenuates")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            if let h = hoverChannel {
                let p = state.channelPositions[h] ?? .zero
                Text(String(format: "Ch %d  ·  x %.1f m  z %.1f m  ·  vol %.0f%%",
                             h + 1, p.x, p.z,
                             Double(h < state.channelVolumes.count ? state.channelVolumes[h] : 0) * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Drawing

    private func drawGrid(in ctx: GraphicsContext, size: CGSize) {
        let cx = size.width / 2
        let cy = size.height / 2
        let radius = min(size.width, size.height) / 2 - 12

        // Concentric distance rings (1 m, 2 m, 4 m, 8 m).
        for ring in [0.125, 0.25, 0.5, 1.0] {
            let r = radius * CGFloat(ring)
            let path = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
        }
        // Cardinal cross — front (top), back (bottom), L (left), R (right).
        var cross = Path()
        cross.move(to: CGPoint(x: cx, y: cy - radius)); cross.addLine(to: CGPoint(x: cx, y: cy + radius))
        cross.move(to: CGPoint(x: cx - radius, y: cy)); cross.addLine(to: CGPoint(x: cx + radius, y: cy))
        ctx.stroke(cross, with: .color(.white.opacity(0.05)), lineWidth: 1)

        // Cardinal labels.
        let labels = [("Front", CGPoint(x: cx, y: cy - radius - 14)),
                      ("Back",  CGPoint(x: cx, y: cy + radius + 14)),
                      ("L",     CGPoint(x: cx - radius - 14, y: cy)),
                      ("R",     CGPoint(x: cx + radius + 14, y: cy))]
        for (s, p) in labels {
            ctx.draw(Text(s).font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4)), at: p)
        }
    }

    private func drawListener(in ctx: GraphicsContext, size: CGSize) {
        let cx = size.width / 2
        let cy = size.height / 2

        // Listener glyph: head circle + nose triangle pointing up (front).
        let r: CGFloat = 12
        let head = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        ctx.fill(head, with: .color(StudioTheme.accent.opacity(0.85)))
        ctx.stroke(head, with: .color(.white.opacity(0.6)), lineWidth: 1)

        var nose = Path()
        nose.move(to: CGPoint(x: cx, y: cy - r - 5))
        nose.addLine(to: CGPoint(x: cx - 5, y: cy - r + 1))
        nose.addLine(to: CGPoint(x: cx + 5, y: cy - r + 1))
        nose.closeSubpath()
        ctx.fill(nose, with: .color(StudioTheme.accent))

        ctx.draw(Text("YOU").font(.system(size: 8, weight: .black, design: .monospaced))
            .foregroundColor(.white.opacity(0.7)),
                 at: CGPoint(x: cx, y: cy + r + 12))
    }

    private func drawChannels(in ctx: GraphicsContext, size: CGSize) {
        for ch in 0..<min(kMaxChannels, 16) {
            let pos = state.channelPositions[ch] ?? defaultPosition(for: ch)
            let p = worldToView(SIMD2(pos.x, pos.z), in: size)
            let isMuted = state.channelMutesPtr[ch] != 0
            let vol = ch < state.channelVolumes.count ? CGFloat(state.channelVolumes[ch]) : 0.5
            let r = max(6, min(20, 6 + vol * 14))

            let baseColor = channelColor(ch).opacity(isMuted ? 0.25 : 1.0)
            let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            ctx.fill(dot, with: .color(baseColor))

            if hoverChannel == ch || dragChannel == ch {
                ctx.stroke(dot, with: .color(.white), lineWidth: 2)
            } else {
                ctx.stroke(dot, with: .color(.white.opacity(0.5)), lineWidth: 1)
            }

            // Distance + angle lines from listener.
            let cx = size.width / 2; let cy = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: cx, y: cy))
            line.addLine(to: p)
            ctx.stroke(line, with: .color(baseColor.opacity(0.25)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Channel number label inside the dot.
            ctx.draw(Text("\(ch + 1)")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(.white),
                     at: p)
        }
    }

    private func drawHoverInfo(in ctx: GraphicsContext, size: CGSize) {
        // Hover state is rendered through the legend overlay — no inline draw
        // needed here, but reserve the hook for future readouts.
        _ = (ctx, size)
    }

    // MARK: - Coordinate conversion

    /// World (metres) → view (pixels), centred on the canvas.
    private func worldToView(_ w: SIMD2<Float>, in size: CGSize) -> CGPoint {
        let cx = size.width / 2
        let cy = size.height / 2
        let radius = min(size.width, size.height) / 2 - 12
        let px = cx + CGFloat(w.x) / extent * radius
        // Z increases away from listener; on screen we put +Z at top (front
        // is towards −Z in PHASE conventions, so flip).
        let py = cy - CGFloat(w.y) / extent * radius
        return CGPoint(x: px, y: py)
    }

    /// View (pixels) → world (metres) on the XZ plane.
    private func viewToWorld(_ p: CGPoint, in size: CGSize) -> SIMD2<Float> {
        let cx = size.width / 2
        let cy = size.height / 2
        let radius = min(size.width, size.height) / 2 - 12
        let x = Float((p.x - cx) / radius * extent)
        let z = Float((cy - p.y) / radius * extent)
        return SIMD2(x, z)
    }

    private func defaultPosition(for ch: Int) -> SIMD3<Float> {
        // Spread the first 16 channels around the listener at 2 m radius
        // so users see something on first launch instead of every dot
        // piled at origin.
        let angle = Float(ch) / 16.0 * (2 * .pi)
        return SIMD3<Float>(2.0 * sin(angle), 0, -2.0 * cos(angle))
    }

    private func closestChannel(to p: CGPoint, in size: CGSize, threshold: CGFloat) -> Int? {
        var best: (ch: Int, d: CGFloat)? = nil
        for ch in 0..<min(kMaxChannels, 16) {
            let pos = state.channelPositions[ch] ?? defaultPosition(for: ch)
            let viewPt = worldToView(SIMD2(pos.x, pos.z), in: size)
            let d = hypot(viewPt.x - p.x, viewPt.y - p.y)
            if d < threshold {
                if best == nil || d < best!.d { best = (ch, d) }
            }
        }
        return best?.ch
    }

    private func handleDrag(at p: CGPoint, size: CGSize) {
        if dragChannel == nil {
            dragChannel = closestChannel(to: p, in: size, threshold: 18)
        }
        guard let ch = dragChannel else { return }
        let world = viewToWorld(p, in: size)
        state.channelPositions[ch] = SIMD3<Float>(world.x, 0, world.y)
    }

    private func channelColor(_ ch: Int) -> Color {
        let palette: [Color] = [
            .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue,
            .indigo, .purple, .pink, Color(white: 0.7),
            Color(red: 0.9, green: 0.6, blue: 0.2),
            Color(red: 0.6, green: 0.9, blue: 0.2),
            Color(red: 0.3, green: 0.7, blue: 0.9),
            Color(red: 0.8, green: 0.3, blue: 0.7),
        ]
        return palette[ch % palette.count]
    }
}
#endif
