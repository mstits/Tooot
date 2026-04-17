/*
 *  PROJECT ToooT (ToooT_UI)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 */

import SwiftUI
import ToooT_Core
import ToooT_Plugins
import ToooT_IO
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import Combine

// MARK: - Main Tracker Workspace

public struct TrackerWorkspace: View {
    @Bindable var state: PlaybackState
    let host: AudioHost?
    let timeline: Timeline?
    
    @State private var isSidebarExpanded: Bool = true
    @State private var isDropHovering: Bool = false

    public init(state: PlaybackState, host: AudioHost? = nil, timeline: Timeline? = nil) {
        self.state = state
        self.host = host
        self.timeline = timeline
    }

    public var body: some View {
        HStack(spacing: 0) {
            if isSidebarExpanded {
                StudioInspector(state: state, timeline: timeline, host: host)
                    .frame(width: 260)
                    .background(StudioTheme.surface)
                    .transition(.move(edge: .leading))
                    .overlay(Rectangle().frame(width: 1).foregroundColor(Color.white.opacity(0.05)), alignment: .trailing)
            }
            
            VStack(spacing: 0) {
                topToolbar
                mainWorkspaceView.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(StudioTheme.background)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(StudioTheme.accent, lineWidth: isDropHovering ? 4 : 0)
                .allowsHitTesting(false)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSidebarExpanded)
        .onDrop(of: [.fileURL], isTargeted: $isDropHovering) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                let ext = url.pathExtension.lowercased()
                DispatchQueue.main.async {
                    if ["mod", "mad", "xm", "it", "s3m"].contains(ext) {
                        NotificationCenter.default.post(name: NSNotification.Name("LoadModFileURL"), object: url)
                    } else if ["wav", "aiff", "aif", "mp3", "flac"].contains(ext) {
                        NotificationCenter.default.post(name: NSNotification.Name("LoadInstrumentFile"), object: url)
                    }
                }
            }
            return true
        }
    }

    private var topToolbar: some View {
        HStack {
            Button(action: { isSidebarExpanded.toggle() }) {
                Image(systemName: "sidebar.left").font(.system(size: 14, weight: .bold))
                    .foregroundColor(isSidebarExpanded ? StudioTheme.accent : .gray)
            }.buttonStyle(.plain)
            
            HStack(spacing: 12) {
                Button(action: { 
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [
                        UTType(filenameExtension: "mod")!,
                        UTType(filenameExtension: "mad")!,
                        UTType(filenameExtension: "madk")!,
                        UTType(filenameExtension: "madg")!,
                        UTType(filenameExtension: "xm")!,
                        UTType(filenameExtension: "it")!,
                        UTType(filenameExtension: "s3m")!
                    ]
                    p.title = "Open Tracker File"
                    if p.runModal() == .OK, let u = p.url { NotificationCenter.default.post(name: NSNotification.Name("LoadModFileURL"), object: u) } 
                }) {                    Image(systemName: "folder.badge.plus").font(.system(size: 14)).foregroundColor(.gray)
                }.buttonStyle(.plain)
                Button(action: { 
                    let p = NSSavePanel(); p.allowedContentTypes = [UTType(exportedAs: "com.apple.mad")]; p.nameFieldStringValue = state.songTitle
                    if p.runModal() == .OK, let u = p.url { 
                        let states = host?.getPluginStates() ?? [:]
                        Task { @MainActor in 
                            let writer = MADWriter()
                            let count = kMaxChannels * 64 * 100
                            try? writer.write(events: state.sequencerData.events, eventCount: count, instruments: state.instruments, orderList: state.orderList, songLength: state.songLength, sampleBank: timeline?.audioEngine?.sampleBank, songTitle: state.songTitle, pluginStates: states, to: u)
                        }
                    }
                }) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 14)).foregroundColor(.gray)
                }.buttonStyle(.plain)
            }.padding(.leading, 10)
            
            Divider().frame(height: 16).padding(.horizontal, 12)
            TransportView(state: state, timeline: timeline)
            Spacer()
            
            HStack(spacing: 4) {
                ViewModeButton(mode: .dashboard, current: $state.activeTab, icon: "house.fill")
                ViewModeButton(mode: .patterns, current: $state.activeTab, icon: "square.grid.3x3.fill")
                ViewModeButton(mode: .pianoRoll, current: $state.activeTab, icon: "pianokeys")
                ViewModeButton(mode: .mixer, current: $state.activeTab, icon: "slider.vertical.3")
                ViewModeButton(mode: .automation, current: $state.activeTab, icon: "waveform.path.badge.minus")
                ViewModeButton(mode: .spatial, current: $state.activeTab, icon: "arkit")
                ViewModeButton(mode: .spectral, current: $state.activeTab, icon: "waveform.and.magnifyingglass")
                ViewModeButton(mode: .plugins, current: $state.activeTab, icon: "fx")
                ViewModeButton(mode: .neural, current: $state.activeTab, icon: "brain.head.profile")
            }
            .padding(4).background(Color.black.opacity(0.3)).cornerRadius(8)
            
            Spacer()
            Button(action: { JITWindowManager.show(state: state, timeline: timeline, host: host) }) {
                HStack(spacing: 6) { Image(systemName: "terminal.fill").font(.system(size: 10)); Text("JIT SHELL").font(.system(size: 9, weight: .black, design: .monospaced)) }
                .padding(.horizontal, 12).padding(.vertical, 6).background(Color.green.opacity(0.2)).foregroundColor(.green).cornerRadius(6)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).frame(height: 44).background(StudioTheme.surface).overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.05)), alignment: .bottom)
    }

    @ViewBuilder
    private var mainWorkspaceView: some View {
        switch state.activeTab {
        case .dashboard:   DashboardView(state: state, timeline: timeline)
        case .patterns:    MetalPatternView(state: state, host: host, timeline: timeline)
        case .pianoRoll:   PianoRollView(state: state, timeline: timeline)
        case .mixer:       MixerView(state: state, timeline: timeline, host: host)
        case .automation:  AutomationView(state: state)
        case .spatial:     MetalSpatialView(state: state)
        case .spectral:    SpectralCanvasView(state: state, sampleBank: timeline?.audioEngine?.sampleBank)
        case .instruments, .samples: SampleEditorView(sampleBank: timeline?.audioEngine?.sampleBank, host: host, state: state)
        case .video:       VideoSyncView(state: state)
        case .plugins:     PluginRackView(state: state)
        case .midi:        MIDIControlView(state: state)
        case .neural:      NeuralIntelligenceView(state: state, timeline: timeline, host: host)
        }
    }
}

// MARK: - Navigation Components

struct ViewModeButton: View {
    let mode: WorkbenchTab; @Binding var current: WorkbenchTab; let icon: String
    var body: some View {
        Button(action: { current = mode }) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).frame(width: 32, height: 28).background(current == mode ? StudioTheme.accent.opacity(0.2) : Color.clear).foregroundColor(current == mode ? StudioTheme.accent : .gray).cornerRadius(6)
        }.buttonStyle(.plain)
    }
}

struct TransportView: View {
    @Bindable var state: PlaybackState; let timeline: Timeline?
    var body: some View {
        HStack(spacing: 8) {
            // Play / Pause
            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("TransportToggle"), object: nil) }) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .foregroundColor(state.isPlaying ? .orange : .green)
                    .frame(width: 24, height: 24)
            }.buttonStyle(.plain)

            // Stop
            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("TransportStop"), object: nil) }) {
                Image(systemName: "stop.fill").foregroundColor(.gray).frame(width: 24, height: 24)
            }.buttonStyle(.plain)

            Divider().frame(height: 16)

            // BPM stepper
            HStack(spacing: 4) {
                Text("BPM").font(.system(size: 7, weight: .black, design: .monospaced)).foregroundColor(.gray)
                Text("\(state.bpm)")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 28, alignment: .trailing)
                Stepper("", value: Binding(get: { state.bpm }, set: { timeline?.setBPM($0) }), in: 32...255, step: 1)
                    .labelsHidden()
            }

            // TPR stepper
            HStack(spacing: 4) {
                Text("TPR").font(.system(size: 7, weight: .black, design: .monospaced)).foregroundColor(.gray)
                Text("\(state.ticksPerRow)")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 20, alignment: .trailing)
                Stepper("", value: Binding(get: { state.ticksPerRow }, set: { timeline?.setTicksPerRow($0) }), in: 1...32, step: 1)
                    .labelsHidden()
            }

            Divider().frame(height: 16)

            // Position counters
            Text("ORD \(String(format: "%02d", state.currentOrder))").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.gray)
            Text("PAT \(String(format: "%02d", state.currentPattern))").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.gray)
            Text("ROW \(String(format: "%02d", state.currentUIRow))").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.gray.opacity(0.6))
            
            Divider().frame(height: 16)
            
            // Metronome & Limiter toggles
            HStack(spacing: 12) {
                Button(action: { state.isMetronomeEnabled.toggle() }) {
                    Image(systemName: "metronome").font(.system(size: 12))
                        .foregroundColor(state.isMetronomeEnabled ? .purple : .gray.opacity(0.4))
                }.buttonStyle(.plain).help("Toggle Metronome")
                
                Button(action: { state.isMasterLimiterEnabled.toggle() }) {
                    Image(systemName: "bolt.shield.fill").font(.system(size: 12))
                        .foregroundColor(state.isMasterLimiterEnabled ? .orange : .gray.opacity(0.4))
                }.buttonStyle(.plain).help("Toggle Master Safety Limiter")
            }
        }
    }
}

public struct DashboardView: View {
    let state: PlaybackState; let timeline: Timeline?
    public var body: some View {
        ZStack {
            StudioTheme.industrialGlow().ignoresSafeArea()
            VStack(spacing: 40) {
                VStack(spacing: 10) {
                    Image(systemName: "music.quarternote.3").font(.system(size: 60)).foregroundStyle(StudioTheme.gradient)
                    Text(state.songTitle.uppercased()).font(.system(size: 30, weight: .black, design: .monospaced)).foregroundStyle(StudioTheme.gradient)
                    Text("PROJECT DASHBOARD").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.gray)
                }
                HStack(spacing: 30) {
                    MetricCard(label: "INSTRUMENTS", value: "\(state.instruments.count)", icon: "pianokeys")
                    MetricCard(label: "CHANNELS", value: "\(kMaxChannels)", icon: "slider.vertical.3")
                    MetricCard(label: "BPM", value: "\(state.bpm)", icon: "metronome")
                }
                HStack(spacing: 20) {
                    WelcomeButton(label: "NEW PROJECT", systemImage: "plus.square.fill", color: .blue) { NotificationCenter.default.post(name: NSNotification.Name("NewTrackerDocument"), object: nil) }
                    WelcomeButton(label: "LOAD MOD/MAD/XM", systemImage: "folder.fill", color: .green) { 
                        let p = NSOpenPanel()
                        p.allowedContentTypes = [
                            UTType(filenameExtension: "mod")!,
                            UTType(filenameExtension: "mad")!,
                            UTType(filenameExtension: "madk")!,
                            UTType(filenameExtension: "madg")!,
                            UTType(filenameExtension: "xm")!,
                            UTType(filenameExtension: "it")!,
                            UTType(filenameExtension: "s3m")!
                        ]
                        p.title = "Open Tracker File"; 
                        if p.runModal() == .OK, let url = p.url { NotificationCenter.default.post(name: NSNotification.Name("LoadModFileURL"), object: url) } 
                    }
                }
                
                VStack(spacing: 12) {
                    Text("GLOBAL SIGNAL ROUTING").font(.system(size: 8, weight: .black)).foregroundColor(.gray)
                    HStack(spacing: 24) {
                        SidechainControl(state: state)
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(12)
                }
            }
        }
    }
}

struct SidechainControl: View {
    @Bindable var state: PlaybackState
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SIDECHAIN SOURCE").font(.system(size: 7, weight: .bold)).foregroundColor(.purple)
                Picker("", selection: $state.sidechainChannel) {
                    Text("DISABLED").tag(-1)
                    ForEach(0..<min(32, kMaxChannels), id: \.self) { i in
                        Text("CHAN \(i + 1)").tag(i)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 100)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("DUCK AMOUNT").font(.system(size: 7, weight: .bold)).foregroundColor(.purple)
                    Spacer()
                    Text("\(Int(state.sidechainAmount * 100))%").font(.system(size: 7, design: .monospaced)).foregroundColor(.gray)
                }
                Slider(value: $state.sidechainAmount, in: 0...1.0)
                    .controlSize(.mini)
                    .frame(width: 120)
            }
        }
    }
}

struct MetricCard: View {
    let label: String; let value: String; let icon: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundColor(.gray)
            Text(value).font(.system(size: 20, weight: .black, design: .monospaced)).foregroundColor(.white)
            Text(label).font(.system(size: 7, weight: .bold)).foregroundColor(.gray)
        }
        .frame(width: 100, height: 80).background(Color.white.opacity(0.05)).cornerRadius(12).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

struct StudioInspector: View {
    @Bindable var state: PlaybackState; let timeline: Timeline?; let host: AudioHost?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                InspectorTab(label: "INST", mode: .instrument, current: Binding(get: { state.inspectorMode }, set: { state.inspectorMode = $0 }))
                InspectorTab(label: "CHAN \(state.selectedChannel + 1)", mode: .channel, current: Binding(get: { state.inspectorMode }, set: { state.inspectorMode = $0 }))
                InspectorTab(label: "BROWSER", mode: .browser, current: Binding(get: { state.inspectorMode }, set: { state.inspectorMode = $0 }))
            }.background(Color.black.opacity(0.3))
            Divider().background(Color.white.opacity(0.1))
            
            Group {
                switch state.inspectorMode {
                case .instrument: InstrumentListView(state: state)
                case .channel:    ChannelInspectorView(state: state)
                case .browser:    SampleBrowserView(state: state)
                }
            }
            
            Spacer()
            
            VStack(spacing: 0) {
                Divider().background(Color.white.opacity(0.1))
                if state.inspectorMode == .instrument {
                    Button(action: { WaveformWindowManager.show(state: state, timeline: timeline, host: host) }) {
                        Label("OPEN WAVEFORM EDITOR", systemImage: "waveform").font(.system(size: 9, weight: .black))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioTheme.accent)
                    .padding(20)
                } else if state.inspectorMode == .channel {
                    ChannelQuickControlsView(state: state)
                } else {
                    // Browser Quick Actions
                    VStack(alignment: .leading, spacing: 10) {
                        Text("QUICK ACTIONS").font(.system(size: 7, weight: .black)).foregroundColor(.gray)
                        Button(action: { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; if p.runModal() == .OK, let u = p.url { state.browserPath = u } }) {
                            Label("CHANGE ROOT", systemImage: "folder.fill").font(.system(size: 8, weight: .bold))
                        }.buttonStyle(.bordered).controlSize(.small)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.background(StudioTheme.glassPanel())
        }
    }
}

struct InstrumentListView: View {
    @Bindable var state: PlaybackState
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(state.instruments.keys.sorted(), id: \.self) { key in
                    InstrumentRowView(state: state, key: key)
                }
            }
        }
    }
}

struct InstrumentRowView: View {
    @Bindable var state: PlaybackState
    let key: Int
    @State private var renameKey: Int? = nil; @State private var renameText: String = ""
    var body: some View {
        let inst = state.instruments[key]; let isSelected = state.selectedInstrument == key && state.inspectorMode == .instrument
        HStack {
            Text(String(format: "%02X", key)).font(.system(size: 9, weight: .black, design: .monospaced)).foregroundColor(isSelected ? .white : .gray).padding(4).background(isSelected ? StudioTheme.accent : Color.gray.opacity(0.2)).cornerRadius(4)
            if renameKey == key { TextField("", text: $renameText).onSubmit { if var i = inst { i.nameString = renameText; state.instruments[key] = i }; renameKey = nil } }
            else { Text(inst?.nameString ?? "Inst \(key)").font(.system(size: 10, design: .monospaced)).foregroundColor(isSelected ? .white : .gray) }
            Spacer(); if isSelected { Circle().fill(StudioTheme.accent).frame(width: 6, height: 6) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
        .background(isSelected ? StudioTheme.accent.opacity(0.15) : Color.clear).cornerRadius(4)
        .onTapGesture { state.selectInstrument(key) }
        .contextMenu { Button("Rename Instrument") { renameKey = key; renameText = inst?.nameString ?? "" } }
    }
}

struct ChannelInspectorView: View {
    @Bindable var state: PlaybackState
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ModuleHeader(title: "PLUGIN CHAIN"); VStack(spacing: 8) { PluginChainSlot(name: "Stereo Wide"); PluginChainSlot(name: "Pro Reverb"); Button(action: { state.activePluginDialog = .amplitude }) { Label("ADD PLUGIN", systemImage: "plus.circle.fill").font(.system(size: 8, weight: .black)) }.buttonStyle(.bordered).padding(.top, 10) }.padding(.horizontal)
            ModuleHeader(title: "SPATIAL 3D"); MetalSpatialView(state: state).frame(height: 150)
        }
    }
}

struct ChannelQuickControlsView: View {
    @Bindable var state: PlaybackState
    var body: some View {
        VStack(spacing: 15) {
            Divider().background(Color.white.opacity(0.1)); HStack { StudioKnob(label: "PAN", value: Binding(get: { state.channelPansPtr[state.selectedChannel] }, set: { state.setPan($0, for: state.selectedChannel) })); Spacer()
                VStack(spacing: 4) { MuteSoloButton(label: "M", isActive: state.channelMutesPtr[state.selectedChannel] != 0, color: .red) { state.setMute(state.channelMutesPtr[state.selectedChannel] == 0, for: state.selectedChannel) }; MuteSoloButton(label: "S", isActive: state.channelSolosPtr[state.selectedChannel] != 0, color: .yellow) { state.setSolo(state.channelSolosPtr[state.selectedChannel] == 0, for: state.selectedChannel) } }
            }.padding(20)
        }.background(StudioTheme.glassPanel())
    }
}

struct InspectorTab: View {
    let label: String; let mode: PlaybackState.InspectorMode; @Binding var current: PlaybackState.InspectorMode
    var body: some View { Button(action: { current = mode }) { VStack(spacing: 0) { Text(label).font(.system(size: 8, weight: .black, design: .monospaced)).foregroundColor(current == mode ? .white : .gray).frame(maxWidth: .infinity).frame(height: 32); Rectangle().fill(current == mode ? StudioTheme.accent : Color.clear).frame(height: 2) } }.buttonStyle(.plain) }
}

struct PluginChainSlot: View {
    let name: String
    var body: some View { HStack { Circle().fill(Color.green).frame(width: 4, height: 4); Text(name).font(.system(size: 9, weight: .bold, design: .monospaced)); Spacer(); Image(systemName: "power").font(.system(size: 8)).foregroundColor(.green) }.padding(8).background(Color.white.opacity(0.05)).cornerRadius(4) }
}

struct ModuleHeader: View {
    let title: String
    var body: some View { HStack { Text(title).font(.system(size: 9, weight: .black, design: .monospaced)).foregroundColor(.gray); Spacer() }.padding(.horizontal, 16).padding(.vertical, 8).background(Color.white.opacity(0.02)) }
}

public struct MixerView: View {
    @Bindable var state: PlaybackState; let timeline: Timeline?; let host: AudioHost?
    public init(state: PlaybackState, timeline: Timeline? = nil, host: AudioHost? = nil) { self.state = state; self.timeline = timeline; self.host = host }
    public var body: some View {
        ZStack {
            StudioTheme.industrialGlow().ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 40) {
                    VStack(alignment: .leading, spacing: 4) { Text("MASTER OUTPUT").font(.system(size: 8, weight: .black)).foregroundColor(.blue.opacity(0.8)); Text("\(Int(state.masterVolume * 100))%").font(.system(size: 32, weight: .black, design: .monospaced)).foregroundStyle(StudioTheme.gradient) }
                    StudioFader(value: Binding(get: { Float(state.masterVolume) }, set: { state.masterVolume = Double($0); timeline?.publishSnapshot() }), isMuted: false).frame(width: 40, height: 140)
                    MasterMeterView(state: state).frame(height: 140); Spacer(); ExportDialogView(timeline: timeline, host: host, state: state)
                }.padding(24).background(StudioTheme.glassPanel())
                Divider().background(Color.white.opacity(0.1))
                ViewportVirtualizer(totalItems: kMaxChannels, itemWidth: 75) { ch in ChannelStripView(state: state, index: ch) }.frame(height: 300)
            }
        }
    }
}

struct MasterMeterView: View {
    let state: PlaybackState
    var body: some View { HStack(spacing: 2) { MeterBar(level: state.peakLevel); MeterBar(level: state.peakLevel * 0.9) }.frame(width: 40, height: 40) }
}

struct MeterBar: View {
    let level: Float
    var body: some View { GeometryReader { geo in ZStack(alignment: .bottom) { Rectangle().fill(Color.gray.opacity(0.2)); Rectangle().fill(level > 0.9 ? Color.red : (level > 0.7 ? Color.yellow : Color.green)).frame(height: geo.size.height * CGFloat(min(1.0, max(0, level)))) } } }
}

struct ChannelStripView: View {
    @Bindable var state: PlaybackState; let index: Int
    var body: some View {
        let _ = state.mixerGeneration; let isMuted = state.channelMutesPtr[index] != 0; let isSelected = state.selectedChannel == index && state.inspectorMode == .channel
        VStack(spacing: 10) {
            Text("\(String(format: "%04d", index + 1))").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(isMuted ? .red : (isSelected ? StudioTheme.accent : .gray))
            StudioKnob(label: "PAN", value: Binding(get: { state.channelPansPtr[index] }, set: { state.setPan($0, for: index) }))
            StudioFader(value: Binding(get: { state.channelVolumesPtr[index] }, set: { state.setVolume($0, for: index) }), isMuted: isMuted).frame(height: 120)
            HStack(spacing: 4) { MuteSoloButton(label: "M", isActive: isMuted, color: .red) { state.setMute(!isMuted, for: index) }; MuteSoloButton(label: "S", isActive: state.channelSolosPtr[index] != 0, color: .yellow) { state.setSolo(state.channelSolosPtr[index] == 0, for: index) } }
        }.frame(width: 60).padding(.vertical, 12).background(isSelected ? StudioTheme.accent.opacity(0.1) : (index % 2 == 0 ? Color.white.opacity(0.02) : Color.clear)).contentShape(Rectangle()).onTapGesture { state.selectChannel(index) }.overlay(Rectangle().frame(width: 1).foregroundColor(Color.white.opacity(0.05)), alignment: .trailing)
    }
}

struct MuteSoloButton: View {
    let label: String; let isActive: Bool; let color: Color; let action: () -> Void
    var body: some View { Button(action: action) { Text(label).font(.system(size: 8, weight: .black)).frame(width: 22, height: 22).background(isActive ? color : Color.gray.opacity(0.15)).foregroundColor(isActive ? .black : .gray).cornerRadius(4) }.buttonStyle(.plain) }
}

public struct SampleEditorView: View {
    let sampleBank: UnifiedSampleBank?; let host: AudioHost?; @Bindable var state: PlaybackState
    @State private var zoomLevel: Double = 1.0; public init(sampleBank: UnifiedSampleBank? = nil, host: AudioHost? = nil, state: PlaybackState) { self.sampleBank = sampleBank; self.host = host; self.state = state }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 2) { Text("WAVEFORM FORGE 2.0").font(.system(size: 11, weight: .black, design: .monospaced)).foregroundStyle(StudioTheme.gradient); Text("PRECISION PCM EDITOR [INST \(String(format: "%02X", state.selectedInstrument))]").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(.blue.opacity(0.6)) }; Spacer(); HStack(spacing: 12) { Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundColor(.gray); Slider(value: $zoomLevel, in: 1.0...100.0).frame(width: 80).controlSize(.mini) }; Button(action: { 
                let p = NSOpenPanel()
                p.allowedContentTypes = [.wav, .aiff, .mp3, .mpeg4Audio, UTType(filenameExtension: "flac")!, UTType(filenameExtension: "ogg")!]
                p.title = "Import Sample (WAV / AIFF / MP3 / M4A / FLAC)"
                if p.runModal() == .OK, let u = p.url { NotificationCenter.default.post(name: NSNotification.Name("LoadInstrumentFile"), object: u) } 
            }) { Label("IMPORT", systemImage: "plus.circle.fill").font(.system(size: 8, weight: .black)) }.buttonStyle(.bordered).controlSize(.small); RecordingControlsView(state: state, host: host) }.padding(.horizontal, 16).padding(.vertical, 10).background(StudioTheme.glassPanel())
            GeometryReader { geo in ZStack { Color.black.opacity(0.6); if let bank = sampleBank, let inst = state.instruments[state.selectedInstrument], inst.regionCount > 0 { WaveformRenderer(pointer: bank.samplePointer.advanced(by: inst.regions.0.offset), count: inst.regions.0.length).stroke(StudioTheme.gradient, lineWidth: 1.5); Path { path in for i in 0..<10 { let x = geo.size.width * CGFloat(i) / 10; path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geo.size.height)) } }.stroke(Color.white.opacity(0.05), lineWidth: 0.5) } else { VStack(spacing: 12) { Image(systemName: "waveform.path.badge.plus").font(.system(size: 30)).foregroundColor(.gray.opacity(0.3)); Text("DRAG AUDIO OR CLICK IMPORT").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(.gray.opacity(0.5)) }.frame(maxWidth: .infinity, maxHeight: .infinity) } } }.frame(minHeight: 160, maxHeight: .infinity).overlay(Rectangle().stroke(Color.white.opacity(0.1), lineWidth: 1))
            HStack(spacing: 8) {
                DSPButton(label: "MAXIMIZE") {
                    guard let bank = sampleBank else { return }
                    let reg = state.instruments[state.selectedInstrument]?.regions.0
                    let off = reg?.offset ?? 0; let len = reg?.length ?? 0
                    state.snapshotDSPUndo(bank: bank, offset: off, length: len, instrument: state.selectedInstrument)
                    OfflineDSP.normalize(bank: bank, offset: off, length: len); state.textureInvalidationTrigger += 1
                }
                DSPButton(label: "REVERSE") {
                    guard let bank = sampleBank else { return }
                    let reg = state.instruments[state.selectedInstrument]?.regions.0
                    let off = reg?.offset ?? 0; let len = reg?.length ?? 0
                    state.snapshotDSPUndo(bank: bank, offset: off, length: len, instrument: state.selectedInstrument)
                    OfflineDSP.backwards(bank: bank, offset: off, length: len); state.textureInvalidationTrigger += 1
                }
                DSPButton(label: "SILENCE") {
                    guard let bank = sampleBank else { return }
                    let reg = state.instruments[state.selectedInstrument]?.regions.0
                    let off = reg?.offset ?? 0; let len = reg?.length ?? 0
                    state.snapshotDSPUndo(bank: bank, offset: off, length: len, instrument: state.selectedInstrument)
                    OfflineDSP.silence(bank: bank, offset: off, length: len); state.textureInvalidationTrigger += 1
                }
                if state.canUndoDSP {
                    DSPButton(label: "UNDO DSP") {
                        if let bank = sampleBank { state.restoreDSPUndo(bank: bank); state.showStatus("DSP undo restored") }
                    }
                }
                Spacer()
                Text("44.1kHz / 32-bit Float").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(.gray.opacity(0.4))
            }.padding(10).background(Color.black.opacity(0.3))
        }.cornerRadius(12).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.05), lineWidth: 1)).padding()
    }
}

public struct AutomationView: View {
    @Bindable var state: PlaybackState; @State private var selectedParam = "Volume"
    public init(state: PlaybackState) { self.state = state }
    public var body: some View {
        VStack(spacing: 12) {
            HStack { Text("AUTOMATION").font(.system(size: 11, weight: .black, design: .monospaced)).foregroundStyle(StudioTheme.gradient); Spacer(); Picker("", selection: $selectedParam) { Text("Volume").tag("Volume"); Text("Panning").tag("Panning") }.pickerStyle(.segmented).frame(width: 150) }.padding(.horizontal)
            GeometryReader { geo in ZStack { RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.4)); Canvas { context, size in let ch = state.selectedChannel; guard let lanes = state.automationLanes[ch], let lane = lanes.first(where: { $0.parameter == selectedParam }) else { return }; var path = Path(); for i in 0..<lane.points.count { let pt = lane.points[i]; let p = CGPoint(x: pt.time * size.width, y: (1.0 - pt.value) * size.height); if i == 0 { path.move(to: p) } else { let prev = lane.points[i-1]; let prevP = CGPoint(x: prev.time * size.width, y: (1.0 - prev.value) * size.height); let cp = CGPoint(x: prevP.x + (p.x - prevP.x) * 0.5 + prev.controlPoint.x, y: prevP.y + (p.y - prevP.y) * 0.5 + prev.controlPoint.y); path.addQuadCurve(to: p, control: cp) } }; context.stroke(path, with: .color(StudioTheme.accent), lineWidth: 2); for pt in lane.points { let p = CGPoint(x: pt.time * size.width, y: (1.0 - pt.value) * size.height); context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(StudioTheme.accent)) } }.gesture(DragGesture(minimumDistance: 0).onChanged { v in let ch = state.selectedChannel; guard let lanes = state.automationLanes[ch], let lIdx = lanes.firstIndex(where: { $0.parameter == selectedParam }) else { return }; if let idx = state.draggedPointIndex { var pts = lanes[lIdx].points; if NSEvent.modifierFlags.contains(.option) { pts[idx].controlPoint.y = Double(v.translation.height) } else { pts[idx].time = Double(v.location.x / geo.size.width).clamped(to: 0...1.0); pts[idx].value = Double(1.0 - v.location.y / geo.size.height).clamped(to: 0...1.0) }; state.automationLanes[ch]?[lIdx].points = pts.sorted { $0.time < $1.time } } else { for (idx, pt) in lanes[lIdx].points.enumerated() { let p = CGPoint(x: pt.time * geo.size.width, y: (1.0 - pt.value) * geo.size.height); if sqrt(pow(p.x - v.startLocation.x, 2) + pow(p.y - v.startLocation.y, 2)) < 12 { state.draggedPointIndex = idx; break } } } }.onEnded { v in if state.draggedPointIndex == nil { addPoint(at: v.location, in: geo.size) }; state.draggedPointIndex = nil }) } }.frame(maxHeight: .infinity).padding(.horizontal).padding(.bottom)
        }
    }
    private func addPoint(at location: CGPoint, in size: CGSize) { let ch = state.selectedChannel; if state.automationLanes[ch] == nil { state.automationLanes[ch] = [] }; let t = Double(location.x / size.width).clamped(to: 0...1.0); let v = Double(1.0 - location.y / size.height).clamped(to: 0...1.0); if let idx = state.automationLanes[ch]?.firstIndex(where: { $0.parameter == selectedParam }) { state.automationLanes[ch]?[idx].points.append(AutomationPoint(time: t, value: v)); state.automationLanes[ch]?[idx].points.sort { $0.time < $1.time } } else { state.automationLanes[ch]?.append(AutomationLane(parameter: selectedParam, points: [AutomationPoint(time: t, value: v)])) } }
}

public struct ExportDialogView: View {
    let timeline: Timeline?; let host: AudioHost?; let state: PlaybackState
    @State private var isExporting = false; @State private var fileName = ""
    public init(timeline: Timeline? = nil, host: AudioHost? = nil, state: PlaybackState) { self.timeline = timeline; self.host = host; self.state = state }
    public var body: some View { Button(action: { isExporting = true }) { Label("EXPORT", systemImage: "wave.3.forward").font(.system(size: 10, weight: .black)) }.buttonStyle(.borderedProminent).sheet(isPresented: $isExporting) { VStack(spacing: 20) { Text("Export WAV").font(.headline); TextField("Filename", text: $fileName).textFieldStyle(.roundedBorder); Button("Render") { render() }.buttonStyle(.borderedProminent).disabled(fileName.isEmpty); Button("Cancel") { isExporting = false }.buttonStyle(.bordered) }.padding(40) } }
    private func render() { let p = NSSavePanel(); p.allowedContentTypes = [.wav]; p.nameFieldStringValue = fileName; if p.runModal() == .OK, let u = p.url { Task { @MainActor in do { try await host?.exportAudio(to: u, state: state); state.showStatus("Exported \(u.lastPathComponent)") } catch { state.showStatus("Failed: \(error.localizedDescription)") }; isExporting = false } } }
}

public struct ViewportVirtualizer<Content: View>: View {
    let totalItems: Int; let itemWidth: CGFloat; let content: (Int) -> Content
    public init(totalItems: Int, itemWidth: CGFloat, @ViewBuilder content: @escaping (Int) -> Content) { self.totalItems = totalItems; self.itemWidth = itemWidth; self.content = content }
    public var body: some View { ScrollView(.horizontal) { LazyHStack(spacing: 0) { ForEach(0..<totalItems, id: \.self) { i in content(i).frame(width: itemWidth) } } } }
}

public struct SpectralCanvasView: View {
    @Bindable var state: PlaybackState; let sampleBank: UnifiedSampleBank?
    @State private var lines: [[CGPoint]] = []; @State private var currentLine: [CGPoint] = []; @State private var backgroundImage: NSImage? = nil
    public init(state: PlaybackState, sampleBank: UnifiedSampleBank? = nil) { self.state = state; self.sampleBank = sampleBank }
    public var body: some View {
        VStack(spacing: 12) {
            HStack { VStack(alignment: .leading) { Text("SPECTRAL CANVAS").font(.system(size: 11, weight: .black, design: .monospaced)).foregroundStyle(StudioTheme.gradient); Text("Draw harmonics or trace image").font(.system(size: 8)).foregroundColor(.gray) }; Spacer(); HStack(spacing: 8) { Button("Load Image") { loadImage() }.buttonStyle(.bordered).controlSize(.small); Button("Clear") { lines.removeAll(); backgroundImage = nil }.buttonStyle(.bordered).controlSize(.small); Button("GENERATE") { generateHarmonics() }.buttonStyle(.borderedProminent).controlSize(.small) } }.padding(.horizontal)
            GeometryReader { geo in ZStack { RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.4)); if let img = backgroundImage { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).opacity(0.3).frame(width: geo.size.width, height: geo.size.height).clipped().cornerRadius(12) }; Canvas { context, size in for line in lines + (currentLine.isEmpty ? [] : [currentLine]) { var path = Path(); if let first = line.first { path.move(to: first); for pt in line.dropFirst() { path.addLine(to: pt) } }; context.stroke(path, with: .color(StudioTheme.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)) } }.gesture(DragGesture(minimumDistance: 0).onChanged { currentLine.append($0.location) }.onEnded { _ in if !currentLine.isEmpty { lines.append(currentLine); currentLine = [] } }) } }.frame(height: 250).padding(.horizontal)
        }
    }
    private func loadImage() { let p = NSOpenPanel(); p.allowedContentTypes = [.image, .png, .jpeg]; if p.runModal() == .OK, let u = p.url { backgroundImage = NSImage(contentsOf: u) } }
    private func generateHarmonics() { let pts = lines.flatMap { $0 }; guard !pts.isEmpty, let bank = sampleBank else { return }; let instID = state.selectedInstrument; let offset = state.instruments.values.reduce(0) { max($0, $1.regionCount > 0 ? $1.regions.0.offset + $1.regions.0.length : 0) }; let avgY = pts.map { $0.y }.reduce(0, +) / CGFloat(pts.count); let freq = Float(220.0 + (200.0 - min(200.0, avgY))); OfflineDSP.generateHarmonicSample(bank: bank, offset: offset, length: 44100, baseFreq: freq); var inst = state.instruments[instID] ?? Instrument(); inst.nameString = "Spectral Synth"; inst.setSingleRegion(SampleRegion(offset: offset, length: 44100)); state.instruments[instID] = inst; state.textureInvalidationTrigger += 1; state.showStatus("Generated at \(Int(freq))Hz"); lines.removeAll(); currentLine.removeAll() }
}

public struct NeuralIntelligenceView: View {
    @Bindable var state: PlaybackState; let timeline: Timeline?; let host: AudioHost?
    public init(state: PlaybackState, timeline: Timeline? = nil, host: AudioHost? = nil) { self.state = state; self.timeline = timeline; self.host = host }
    public var body: some View { ScrollView { VStack(spacing: 24) { HStack { VStack(alignment: .leading) { Text("NEURAL INTELLIGENCE").font(.system(size: 14, weight: .black, design: .monospaced)).foregroundStyle(StudioTheme.gradient); Text("Post-Human Generative Algorithms").font(.system(size: 8, weight: .bold)).foregroundColor(.gray) }; Spacer(); Image(systemName: "brain.head.profile").font(.title2).foregroundColor(.purple) }; VStack(alignment: .leading, spacing: 12) { Text("SYNTHESIS TIER").font(.system(size: 9, weight: .bold)).foregroundColor(.gray); Picker("", selection: $state.activeTier) { ForEach(SynthesisTier.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented) }.padding(16).background(Color.black.opacity(0.3)).cornerRadius(12); LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) { AIButton(label: "MARKOV MELODY", systemImage: "chart.bar.xaxis") { markovMelody() }; AIButton(label: "EUCLIDEAN BEAT", systemImage: "circle.grid.3x3.fill") { drumRephase() }; AIButton(label: "L-SYSTEM ARP", systemImage: "leaf.fill") { lSystemGen() }; AIButton(label: "NEURAL HARMONY", systemImage: "tuningfork") { neuralHarmony() } }; VStack(alignment: .leading, spacing: 12) { Text("TIER PARAMETERS").font(.system(size: 9, weight: .bold)).foregroundColor(.gray); switch state.activeTier { case .carbon: TierKnob(label: "CORRUPTION", value: $state.carbonCorruption); TierKnob(label: "GLITCH RATE", value: $state.carbonGlitchRate); case .biological: TierKnob(label: "ARRHYTHMIA", value: $state.bioArrhythmiaRate); TierKnob(label: "BREATHINESS", value: $state.bioBreathiness); case .xenomorph: TierKnob(label: "FRACTAL DIM", value: $state.xenoFractalDim); TierKnob(label: "VOID GATE", value: $state.xenoVoidThreshold) } }.padding(16).background(Color.black.opacity(0.3)).cornerRadius(12) }.padding(24) } }
    private func markovMelody() { Task.detached { let matrix = MarkovTransitionMatrix.shared; let (pat, events) = await MainActor.run { (state.currentPattern, (0..<64*kMaxChannels).map { state.sequencerData.events[(state.currentPattern*64*kMaxChannels) + $0] }) }; var prev: Int? = nil; for r in 0..<64 { let ev = events[r * kMaxChannels]; if ev.type == .noteOn { let m = Int(12.0 * log2(Double(ev.value1) / 440.0) + 69.0).clamped(to: 0...127); if let p = prev { matrix.observe(from: p, to: m) }; prev = m } }; matrix.normalize(); var seed = prev ?? 60; var results = [(Int, Float)](); for r in stride(from: 0, to: 64, by: 4) { seed = matrix.predict(from: seed).clamped(to: 36...84); results.append((r, Float(440.0 * pow(2.0, (Double(seed) - 69.0) / 12.0)))) }; await MainActor.run { state.snapshotForUndo(); for (r, f) in results { state.sequencerData.events[(pat * 64 + r) * kMaxChannels + 4] = TrackerEvent(type: .noteOn, channel: 4, instrument: 1, value1: f) }; timeline?.publishSnapshot(); state.textureInvalidationTrigger += 1; state.showStatus("Markov Generated") } } }
    private func drumRephase() { let kick = EuclideanGenerator.generate(pulses: 4, steps: 16); let snare = EuclideanGenerator.generate(pulses: 2, steps: 16); state.snapshotForUndo(); let pat = state.currentPattern; for i in 0..<64 { let r = i % 16; let off = (pat * 64 + i) * kMaxChannels; if kick[r] { state.sequencerData.events[off + 0] = TrackerEvent(type: .noteOn, channel: 0, instrument: 1, value1: 440) }; if snare[r] { state.sequencerData.events[off + 1] = TrackerEvent(type: .noteOn, channel: 1, instrument: 2, value1: 440) } }; timeline?.publishSnapshot(); state.textureInvalidationTrigger += 1; state.showStatus("Euclidean Generated") }
    private func lSystemGen() { let seq = LSystemGenerator.fibonacci(seed: 0, iterations: 4); state.snapshotForUndo(); let pat = state.currentPattern; for (i, val) in seq.prefix(64).enumerated() { let f = Float(261.63 * pow(2.0, Double(val) / 12.0)); state.sequencerData.events[(pat * 64 + i) * kMaxChannels + 5] = TrackerEvent(type: .noteOn, channel: 5, instrument: 1, value1: f) }; timeline?.publishSnapshot(); state.textureInvalidationTrigger += 1; state.showStatus("L-System Generated") }
    private func neuralHarmony() { state.snapshotForUndo(); let pat = state.currentPattern; for r in 0..<64 { let off = (pat * 64 + r) * kMaxChannels; let ev = state.sequencerData.events[off]; if ev.type == .noteOn { state.sequencerData.events[off + 2] = TrackerEvent(type: .noteOn, channel: 2, instrument: ev.instrument, value1: ev.value1 * 1.4983) } }; timeline?.publishSnapshot(); state.textureInvalidationTrigger += 1; state.showStatus("Harmony Generated") }
}

// VideoSyncView moved to Sources/ToooT_UI/VideoSync.swift (proper AVPlayer model +
// drift-based resync + drag-and-drop). This file keeps the tracker workspace tidy.
struct LegacyVideoSyncViewUnused: View {
    var body: some View { EmptyView() }
}

struct RecordingControlsView: View {
    @Bindable var state: PlaybackState; let host: AudioHost?
    public init(state: PlaybackState, host: AudioHost? = nil) { self.state = state; self.host = host }
    var body: some View { Button(action: { if state.isRecording { host?.stopRecording(state: state) } else { host?.startRecording(state: state) } }) { Circle().fill(state.isRecording ? Color.red : Color.gray.opacity(0.5)).frame(width: 12, height: 12).overlay(Circle().stroke(Color.white, lineWidth: 1)) }.buttonStyle(.plain) }
}

public struct MIDIControlView: View {
    @Bindable var state: PlaybackState; public init(state: PlaybackState) { self.state = state }
    public var body: some View { VStack(spacing: 20) { HStack { Text("MIDI I/O CONFIG").font(.system(size: 11, weight: .black, design: .monospaced)).foregroundStyle(StudioTheme.gradient); Spacer() }.padding(.horizontal); List(0..<16, id: \.self) { ch in HStack { Text("Channel \(ch + 1)").font(.system(size: 10, design: .monospaced)); Spacer(); Toggle("", isOn: Binding(get: { state.midiChannelsPtr[ch] != 0 }, set: { state.midiChannelsPtr[ch] = $0 ? 1 : 0 })).controlSize(.mini) } }.listStyle(.plain).frame(height: 200).cornerRadius(8).padding(.horizontal) } }
}

@MainActor
class WaveformWindowManager {
    static var sharedPanel: NSPanel?

    static func show(state: PlaybackState, timeline: Timeline?, host: AudioHost?) {
        if let panel = sharedPanel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let editorView = SampleEditorView(sampleBank: timeline?.audioEngine?.sampleBank, host: host, state: state)
            .frame(minWidth: 800, minHeight: 400)
            .background(StudioTheme.background)

        let hostingController = NSHostingController(rootView: editorView)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.title = "Waveform Forge 2.0"
        panel.contentViewController = hostingController
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.center()
        
        panel.isReleasedWhenClosed = false
        
        sharedPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }
}

@MainActor
class JITWindowManager {
    static var sharedPanel: NSPanel?

    static func show(state: PlaybackState, timeline: Timeline?, host: AudioHost? = nil) {
        if let panel = sharedPanel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let consoleView = JITConsoleView(state: state, timeline: timeline, host: host)
            .frame(minWidth: 500, minHeight: 300)
            .background(StudioTheme.surface.opacity(0.98))

        let hostingController = NSHostingController(rootView: consoleView)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.title = "ToooTShell JIT 3.0"
        panel.contentViewController = hostingController
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.center()
        
        panel.isReleasedWhenClosed = false
        
        sharedPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Sample Browser

@MainActor
struct SampleBrowserView: View {
    @Bindable var state: PlaybackState
    @State private var items: [URL] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // Path Breadcrumbs
            HStack {
                Text(state.browserPath.lastPathComponent.uppercased())
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(StudioTheme.accent)
                Spacer()
                Button(action: { state.browserPath = state.browserPath.deletingLastPathComponent() }) {
                    Image(systemName: "arrow.up.doc.fill").font(.system(size: 10)).foregroundColor(.gray)
                }.buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.white.opacity(0.03))
            
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items, id: \.self) { url in
                        BrowserItem(url: url) {
                            if url.hasDirectoryPath {
                                state.browserPath = url
                            } else {
                                let ext = url.pathExtension.lowercased()
                                if ["mod", "mad", "xm", "it"].contains(ext) {
                                    NotificationCenter.default.post(name: NSNotification.Name("LoadModFileURL"), object: url)
                                } else {
                                    NotificationCenter.default.post(name: NSNotification.Name("LoadInstrumentFile"), object: url)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { refresh() }
        .onChange(of: state.browserPath) { refresh() }
    }
    
    private func refresh() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: state.browserPath, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        
        // Sort: Directories first, then Files
        self.items = contents.sorted { a, b in
            if a.hasDirectoryPath != b.hasDirectoryPath {
                return a.hasDirectoryPath
            }
            return a.lastPathComponent.lowercased() < b.lastPathComponent.lowercased()
        }.filter { url in
            if url.hasDirectoryPath { return true }
            let ext = url.pathExtension.lowercased()
            return ["wav", "aif", "aiff", "mp3", "flac", "mod", "mad", "xm", "it", "s3m"].contains(ext)
        }
    }
}

struct BrowserItem: View {
    let url: URL
    let action: () -> Void
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: url.hasDirectoryPath ? "folder.fill" : "doc.audio.fill")
                    .font(.system(size: 10))
                    .foregroundColor(url.hasDirectoryPath ? .orange.opacity(0.7) : .blue.opacity(0.7))
                
                Text(url.lastPathComponent)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(isHovering ? .white : .gray)
                    .lineLimit(1)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovering ? Color.white.opacity(0.05) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .draggable(url) // Support dragging items FROM browser to workspace
    }
}
