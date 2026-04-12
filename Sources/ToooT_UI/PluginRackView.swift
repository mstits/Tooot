/*
 *  PROJECT ToooT (ToooT_UI)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  Industrial Plugin Rack — Modular Signal Chain.
 */

import SwiftUI
import ToooT_Core

@MainActor
public struct PluginRackView: View {
    @Bindable var state: PlaybackState

    let filterPlugs: [PluginType] = [.amplitude, .backwards, .depth, .echo, .fade, .invert, .normalize, .silence, .toneGenerator]
    let digitalPlugs: [PluginType] = [.complexFade, .fadeNote, .fadeVolume, .noteTranslate, .propagate, .revert]
    let ioPlugs: [PluginType] = [.importMIDI, .importClassicApp, .ioAIFF, .ioWave, .ioQuickTime]

    public init(state: PlaybackState) { self.state = state }

    public var body: some View {
        ZStack {
            StudioTheme.industrialGlow().ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    RackSection(title: "ANALOG-EMU OFFLINE", subtitle: "High-Precision Sample Forge", plugs: filterPlugs, color: .cyan, state: state)
                    RackSection(title: "DIGITAL LOGIC ENGINE", subtitle: "Algorithmic Pattern Mutators", plugs: digitalPlugs, color: .green, state: state)
                    RackSection(title: "SIGNAL BRIDGING", subtitle: "External IO & Transpilation", plugs: ioPlugs, color: .orange, state: state)
                }
                .padding(30)
            }
        }
    }
}

struct RackSection: View {
    let title: String; let subtitle: String; let plugs: [PluginType]; let color: Color
    @Bindable var state: PlaybackState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11, weight: .black, design: .monospaced)).foregroundColor(color)
                    Text(subtitle).font(.system(size: 8, weight: .bold)).foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                Rectangle().fill(color.opacity(0.3)).frame(height: 1).padding(.bottom, 4)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 12) {
                ForEach(plugs, id: \.self) { plug in
                    RackSlot(plug: plug, state: state, color: color)
                }
            }
        }
    }
}

struct RackSlot: View {
    let plug: PluginType; @Bindable var state: PlaybackState; let color: Color
    @State private var isHovering = false
    
    var body: some View {
        Button(action: { state.activePluginDialog = plug }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(color).frame(width: 6, height: 6)
                        .shadow(color: color, radius: 4)
                    Spacer()
                    Image(systemName: "power").font(.system(size: 8, weight: .black)).foregroundColor(.white.opacity(0.3))
                }
                
                Text(plug.rawValue.uppercased())
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                
                HStack(spacing: 2) {
                    ForEach(0..<8) { _ in
                        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 4, height: 2)
                    }
                }
            }
            .padding(12)
            .background(StudioTheme.glassPanel())
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isHovering ? color.opacity(0.6) : Color.white.opacity(0.05), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
