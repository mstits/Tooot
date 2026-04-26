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
                .help(state.isPlaying ? "Pause (Space)" : "Play (Space)")

            // Stop
            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("TransportStop"), object: nil) }) {
                Image(systemName: "stop.fill").foregroundColor(.gray).frame(width: 24, height: 24)
            }.buttonStyle(.plain)
                .help("Stop / panic (⌘.)")

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
            .help("Beats per minute (32–255). Tempo automation can override this during playback.")

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
            .help("Ticks per row — sub-row resolution for tracker effects. Standard is 6.")

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
    @Bindable var state: PlaybackState
    @State private var selectedParam: String = "ch.0.volume"
    @State private var selectedPoint: BezierAutomationPoint.ID?
    @State private var didDrag: Bool = false

    public init(state: PlaybackState) { self.state = state }

    /// All automation targets the user can edit. Native engine targets up
    /// front; per-channel/per-bus repeated. Plugin params get appended at
    /// runtime when a host registers them.
    private var availableParams: [(label: String, id: String)] {
        var out: [(String, String)] = [
            ("Master Volume", "master.volume"),
            ("Tempo (BPM)",   "tempo.bpm"),
        ]
        for ch in 0..<8 {
            out.append(("Ch \(ch + 1) Volume", "ch.\(ch).volume"))
            out.append(("Ch \(ch + 1) Pan",    "ch.\(ch).pan"))
        }
        for b in 0..<kAuxBusCount {
            out.append(("Bus \(b + 1) Volume", "bus.\(b).volume"))
        }
        return out
    }

    public var body: some View {
        HStack(spacing: 0) {
            paramSidebar
                .frame(width: 200)
                .background(Color.black.opacity(0.35))

            VStack(alignment: .leading, spacing: 12) {
                header
                editor
                pointInspector
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Sidebar

    private var paramSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PARAMETERS")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(StudioTheme.gradient)
                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(availableParams, id: \.id) { item in
                        paramRow(label: item.label, id: item.id)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private func paramRow(label: String, id: String) -> some View {
        let lane = currentLane(targetID: id, channel: 0)
        let isSelected = selectedParam == id
        return HStack {
            Circle()
                .fill(lane != nil ? StudioTheme.accent : Color.gray.opacity(0.3))
                .frame(width: 6, height: 6)
            Text(label).font(.system(size: 11))
            Spacer()
            if let l = lane {
                Text("\(l.points.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(isSelected ? StudioTheme.accent.opacity(0.18) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture { selectedParam = id; selectedPoint = nil }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("AUTOMATION")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(StudioTheme.gradient)
            Text("·").foregroundColor(.secondary)
            Text(currentParamLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            HStack(spacing: 8) {
                Button("Clear")  { clearLane() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(currentLane(targetID: selectedParam, channel: 0) == nil)
                Button("+ Point") { addPointAtMidpoint() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var currentParamLabel: String {
        availableParams.first(where: { $0.id == selectedParam })?.label ?? selectedParam
    }

    // MARK: - Editor canvas

    private var editor: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.4))

                Canvas { ctx, size in
                    drawGrid(ctx: ctx, size: size)
                    drawCurrentLane(ctx: ctx, size: size)
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .local)
                        .onChanged { v in handleDragChanged(v: v, size: geo.size) }
                        .onEnded   { v in handleDragEnded(v: v, size: geo.size) }
                )
                .help("Click to insert a point. Drag a point to move it. Use the inspector to change curve type.")

                // Edge labels.
                edgeLabels(size: geo.size)
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func edgeLabels(size: CGSize) -> some View {
        VStack {
            HStack {
                Text("max").font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.4))
                Spacer()
                Text("end").font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            HStack {
                Text("min").font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.4))
                Spacer()
                Text("start").font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(8)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        // Time gridlines: 16 vertical lines (every 1/16 of song length).
        for i in 1..<16 {
            let x = size.width * CGFloat(i) / 16
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(.white.opacity(i % 4 == 0 ? 0.10 : 0.04)), lineWidth: 1)
        }
        // Value gridlines: at 0.25, 0.5, 0.75.
        for v in [0.25, 0.5, 0.75] {
            let y = size.height * CGFloat(v)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(.white.opacity(v == 0.5 ? 0.10 : 0.05)), lineWidth: 1)
        }
        // 50%-line label
        ctx.draw(Text("50%").font(.system(size: 9, design: .monospaced))
            .foregroundColor(.white.opacity(0.3)),
                 at: CGPoint(x: 22, y: size.height / 2))
    }

    private func drawCurrentLane(ctx: GraphicsContext, size: CGSize) {
        guard let lane = currentLane(targetID: selectedParam, channel: 0),
              !lane.points.isEmpty else {
            // Empty state hint.
            ctx.draw(Text("click anywhere to add a point")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35)),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }

        // Curve.
        var path = Path()
        for (i, pt) in lane.points.enumerated() {
            let p = CGPoint(x: CGFloat(pt.time) * size.width,
                            y: CGFloat(1.0 - pt.value) * size.height)
            if i == 0 {
                path.move(to: p)
            } else {
                let prev = lane.points[i - 1]
                let prevP = CGPoint(x: CGFloat(prev.time) * size.width,
                                    y: CGFloat(1.0 - prev.value) * size.height)
                let cp = CGPoint(
                    x: prevP.x + (p.x - prevP.x) * 0.5 + prev.controlPoint.x,
                    y: prevP.y + (p.y - prevP.y) * 0.5 + prev.controlPoint.y)
                path.addQuadCurve(to: p, control: cp)
            }
        }
        ctx.stroke(path, with: .color(StudioTheme.accent), lineWidth: 2)

        // Filled area below.
        var fill = path
        if let last = lane.points.last, let first = lane.points.first {
            fill.addLine(to: CGPoint(x: CGFloat(last.time) * size.width, y: size.height))
            fill.addLine(to: CGPoint(x: CGFloat(first.time) * size.width, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(StudioTheme.accent.opacity(0.15)))
        }

        // Points.
        for pt in lane.points {
            let p = CGPoint(x: CGFloat(pt.time) * size.width,
                            y: CGFloat(1.0 - pt.value) * size.height)
            let isSelected = selectedPoint == pt.id
            let r: CGFloat = isSelected ? 7 : 5
            let ring = Path(ellipseIn: CGRect(x: p.x - r - 2, y: p.y - r - 2,
                                               width: (r + 2) * 2, height: (r + 2) * 2))
            if isSelected {
                ctx.stroke(ring, with: .color(.white.opacity(0.85)), lineWidth: 2)
            }
            let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            ctx.fill(dot, with: .color(StudioTheme.accent))
            ctx.stroke(dot, with: .color(.white.opacity(0.7)), lineWidth: 1)
        }
    }

    // MARK: - Point inspector

    @ViewBuilder
    private var pointInspector: some View {
        if let pid = selectedPoint, let lane = currentLane(targetID: selectedParam, channel: 0),
           let idx = lane.points.firstIndex(where: { $0.id == pid }) {
            let pt = lane.points[idx]
            HStack(spacing: 14) {
                infoBadge("TIME",  String(format: "%.2f", pt.time))
                infoBadge("VALUE", String(format: "%.0f%%", pt.value * 100))
                infoBadge("INDEX", "\(idx + 1) / \(lane.points.count)")

                Picker("Curve out", selection: Binding(
                    get: { pt.controlPoint == .zero ? "linear" : "curve" },
                    set: { newVal in
                        applyToPoint { p in
                            p.controlPoint = (newVal == "linear") ? .zero : CGPoint(x: 0, y: -20)
                        }
                    })) {
                    Text("Linear").tag("linear")
                    Text("S-Curve").tag("curve")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Spacer()

                Button("Delete Point") { deleteSelectedPoint() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(.red)
            }
            .padding(10)
            .background(Color.black.opacity(0.35))
            .cornerRadius(8)
        } else {
            Text("Select a point to edit its curve · click empty space to insert")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
        }
    }

    private func infoBadge(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 8, weight: .bold)).foregroundColor(.gray)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
    }

    // MARK: - Lane access helpers

    private func currentLane(targetID: String, channel: Int) -> BezierAutomationLane? {
        // Lanes are stored under a channel key but the targetID is the
        // canonical identifier. We bucket every lane under channel 0 in
        // the current implementation; per-channel partitioning is the
        // reader's concern.
        for (_, lanes) in state.automationLanes {
            if let l = lanes.first(where: { $0.parameter == targetID }) {
                return l
            }
        }
        return nil
    }

    private func laneIndex(targetID: String) -> (channel: Int, idx: Int)? {
        for (ch, lanes) in state.automationLanes {
            if let i = lanes.firstIndex(where: { $0.parameter == targetID }) {
                return (ch, i)
            }
        }
        return nil
    }

    // MARK: - Mutation

    private func addPoint(at location: CGPoint, in size: CGSize) {
        let t = Double(location.x / size.width).clamped(to: 0...1.0)
        let v = Double(1.0 - location.y / size.height).clamped(to: 0...1.0)
        let newPt = BezierAutomationPoint(time: t, value: v)

        if let (ch, i) = laneIndex(targetID: selectedParam) {
            state.automationLanes[ch]?[i].points.append(newPt)
            state.automationLanes[ch]?[i].points.sort { $0.time < $1.time }
        } else {
            // Stash new lanes under channel 0 — render-path keys on
            // targetID, not channel index.
            var lane = BezierAutomationLane(parameter: selectedParam)
            lane.points = [newPt]
            state.automationLanes[0, default: []].append(lane)
        }
        selectedPoint = newPt.id
    }

    private func addPointAtMidpoint() {
        let pt = BezierAutomationPoint(time: 0.5, value: 0.5)
        if let (ch, i) = laneIndex(targetID: selectedParam) {
            state.automationLanes[ch]?[i].points.append(pt)
            state.automationLanes[ch]?[i].points.sort { $0.time < $1.time }
        } else {
            var lane = BezierAutomationLane(parameter: selectedParam)
            lane.points = [pt]
            state.automationLanes[0, default: []].append(lane)
        }
        selectedPoint = pt.id
    }

    private func clearLane() {
        if let (ch, i) = laneIndex(targetID: selectedParam) {
            state.automationLanes[ch]?.remove(at: i)
        }
        selectedPoint = nil
    }

    private func deleteSelectedPoint() {
        guard let pid = selectedPoint, let (ch, i) = laneIndex(targetID: selectedParam) else { return }
        state.automationLanes[ch]?[i].points.removeAll { $0.id == pid }
        if state.automationLanes[ch]?[i].points.isEmpty == true {
            state.automationLanes[ch]?.remove(at: i)
        }
        selectedPoint = nil
    }

    private func applyToPoint(_ mutate: (inout BezierAutomationPoint) -> Void) {
        guard let pid = selectedPoint, let (ch, li) = laneIndex(targetID: selectedParam),
              let pi = state.automationLanes[ch]?[li].points.firstIndex(where: { $0.id == pid }) else { return }
        var pt = state.automationLanes[ch]![li].points[pi]
        mutate(&pt)
        state.automationLanes[ch]![li].points[pi] = pt
    }

    private func handleDragChanged(v: DragGesture.Value, size: CGSize) {
        if !didDrag {
            // First tick of a drag — try to grab an existing point under
            // the start location.
            if let pid = pointID(at: v.startLocation, size: size, threshold: 14) {
                selectedPoint = pid
            }
            didDrag = true
        }
        guard let pid = selectedPoint, let (ch, li) = laneIndex(targetID: selectedParam),
              let pi = state.automationLanes[ch]?[li].points.firstIndex(where: { $0.id == pid }) else {
            return
        }
        var pts = state.automationLanes[ch]![li].points
        pts[pi].time  = Double(v.location.x / size.width).clamped(to: 0...1.0)
        pts[pi].value = Double(1.0 - v.location.y / size.height).clamped(to: 0...1.0)
        state.automationLanes[ch]?[li].points = pts.sorted { $0.time < $1.time }
    }

    private func handleDragEnded(v: DragGesture.Value, size: CGSize) {
        let movedSignificantly = hypot(v.translation.width, v.translation.height) > 4
        // Tap (no significant movement) without an existing point under
        // the cursor → insert a new point.
        if !movedSignificantly {
            if pointID(at: v.location, size: size, threshold: 14) == nil {
                addPoint(at: v.location, in: size)
            } else if let pid = pointID(at: v.location, size: size, threshold: 14) {
                selectedPoint = pid
            }
        }
        didDrag = false
    }

    private func pointID(at p: CGPoint, size: CGSize, threshold: CGFloat) -> BezierAutomationPoint.ID? {
        guard let lane = currentLane(targetID: selectedParam, channel: 0) else { return nil }
        var best: (id: BezierAutomationPoint.ID, d: CGFloat)? = nil
        for pt in lane.points {
            let pp = CGPoint(x: CGFloat(pt.time) * size.width,
                             y: CGFloat(1.0 - pt.value) * size.height)
            let d = hypot(pp.x - p.x, pp.y - p.y)
            if d < threshold, best == nil || d < best!.d {
                best = (pt.id, d)
            }
        }
        return best?.id
    }
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
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    let host: AudioHost?

    @State private var genStyle: GenerativeStyle = .techno
    @State private var genIntensity: Double = 0.5
    @State private var genComplexity: Double = 0.5
    @State private var genKey: Int = 0          // 0 = C, 11 = B
    @State private var genScale: ScaleKind = .major
    @State private var genVariations: Int = 4
    @State private var genTargetChannel: Int = 0

    public init(state: PlaybackState, timeline: Timeline? = nil, host: AudioHost? = nil) {
        self.state = state; self.timeline = timeline; self.host = host
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                tierCard
                generatorsCard
                parametersCard
                tierKnobsCard

                Text("All generators write into the current pattern at the selected channel. Cmd+Z undoes the most recent generation.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            .padding(24)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("GENERATIVE")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundStyle(StudioTheme.gradient)
                Text("Procedural composition tools")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundColor(.purple)
        }
    }

    private var tierCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SYNTHESIS FLAVOR").font(.system(size: 9, weight: .bold)).foregroundColor(.gray)
            Picker("", selection: $state.activeTier) {
                ForEach(SynthesisTier.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(tierDescription(state.activeTier))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.black.opacity(0.3))
        .cornerRadius(10)
    }

    private var generatorsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GENERATORS").font(.system(size: 9, weight: .bold)).foregroundColor(.gray)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                AIButton(label: "MARKOV MELODY",  systemImage: "chart.bar.xaxis")     { markovMelody() }
                AIButton(label: "EUCLIDEAN BEAT", systemImage: "circle.grid.3x3.fill") { euclideanBeat() }
                AIButton(label: "L-SYSTEM ARP",   systemImage: "leaf.fill")            { lSystemArp() }
                AIButton(label: "HARMONY LAYER",  systemImage: "tuningfork")           { harmonyLayer() }
                AIButton(label: "BASSLINE",       systemImage: "waveform.path")        { generateBassline() }
                AIButton(label: "DRUM PATTERN",   systemImage: "drum")                 { generateDrumPattern() }
                AIButton(label: "CHORD PROG",     systemImage: "pianokeys")            { generateChordProgression() }
                AIButton(label: "VARIATION",      systemImage: "shuffle")              { generateVariation() }
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.3))
        .cornerRadius(10)
    }

    private var parametersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GENERATION CONTROLS").font(.system(size: 9, weight: .bold)).foregroundColor(.gray)

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("STYLE").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                    Picker("", selection: $genStyle) {
                        ForEach(GenerativeStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("KEY").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                    Picker("", selection: $genKey) {
                        ForEach(0..<12, id: \.self) {
                            Text(["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"][$0]).tag($0)
                        }
                    }.pickerStyle(.menu).frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("SCALE").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                    Picker("", selection: $genScale) {
                        ForEach(ScaleKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 14) {
                sliderRow(title: "INTENSITY", value: $genIntensity)
                sliderRow(title: "COMPLEXITY", value: $genComplexity)
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TARGET CHANNEL").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                    Picker("", selection: $genTargetChannel) {
                        ForEach(0..<16, id: \.self) { Text("Ch \($0 + 1)").tag($0) }
                    }.pickerStyle(.menu).frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("VARIATIONS").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                    Stepper("\(genVariations)", value: $genVariations, in: 1...16)
                }
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.3))
        .cornerRadius(10)
    }

    private var tierKnobsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FLAVOR PARAMETERS").font(.system(size: 9, weight: .bold)).foregroundColor(.gray)
            HStack(spacing: 18) {
                switch state.activeTier {
                case .studio:
                    TierKnob(label: "CORRUPTION", value: $state.studioCorruption)
                    TierKnob(label: "GLITCH RATE", value: $state.studioGlitchRate)
                case .organic:
                    TierKnob(label: "TIMING DRIFT", value: $state.organicTimingDrift)
                    TierKnob(label: "BREATHINESS", value: $state.organicBreathiness)
                case .generative:
                    TierKnob(label: "FRACTAL DIM", value: $state.generativeFractalDim)
                    TierKnob(label: "VOID GATE", value: $state.generativeVoidThreshold)
                }
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.3))
        .cornerRadius(10)
    }

    private func sliderRow(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", value.wrappedValue * 100))
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
            }
            Slider(value: value)
        }
    }

    private func tierDescription(_ tier: SynthesisTier) -> String {
        switch tier {
        case .studio:     return "Clean, precise, tracker-classic. Default."
        case .organic:    return "Humanized timing + natural vibrato. Use for ballads, lo-fi, anything that should feel hand-played."
        case .generative: return "Stochastic, glitchy, experimental. Fractal noise + cellular automata. Use for IDM, ambient, sound design."
        }
    }

    // MARK: - Generators

    private func markovMelody() {
        // Snapshot the inputs the Task needs before crossing actors so we
        // don't reach back into MainActor-isolated state from inside.
        let pat = state.currentPattern
        let stridePerStep = max(1, 8 - Int(genComplexity * 6))
        let ch = genTargetChannel
        let eventsCopy = (0..<64 * kMaxChannels).map {
            state.sequencerData.events[(pat * 64 * kMaxChannels) + $0]
        }
        Task.detached {
            let matrix = MarkovTransitionMatrix.shared
            var prev: Int? = nil
            for r in 0..<64 {
                let ev = eventsCopy[r * kMaxChannels]
                if ev.type == .noteOn {
                    let m = Int(12.0 * log2(Double(ev.value1) / 440.0) + 69.0).clamped(to: 0...127)
                    if let p = prev { matrix.observe(from: p, to: m) }
                    prev = m
                }
            }
            matrix.normalize()
            var seed = prev ?? 60
            var results = [(Int, Float)]()
            for r in Swift.stride(from: 0, to: 64, by: stridePerStep) {
                seed = matrix.predict(from: seed).clamped(to: 36...84)
                results.append((r, Float(440.0 * pow(2.0, (Double(seed) - 69.0) / 12.0))))
            }
            await MainActor.run {
                state.snapshotForUndo(label: "Markov Melody")
                for (r, f) in results {
                    state.sequencerData.events[(pat * 64 + r) * kMaxChannels + ch] =
                        TrackerEvent(type: .noteOn, channel: UInt8(ch), instrument: 1, value1: f)
                }
                timeline?.publishSnapshot()
                state.textureInvalidationTrigger += 1
                state.showStatus("Generated Markov melody on Ch \(ch + 1)")
            }
        }
    }

    private func euclideanBeat() {
        let pulses = max(2, Int(2 + genIntensity * 12))
        let kick   = EuclideanGenerator.generate(pulses: pulses,            steps: 16)
        let snare  = EuclideanGenerator.generate(pulses: max(1, pulses - 2), steps: 16)
        state.snapshotForUndo(label: "Euclidean Beat")
        let pat = state.currentPattern
        for i in 0..<64 {
            let r = i % 16
            let off = (pat * 64 + i) * kMaxChannels
            if kick[r]  { state.sequencerData.events[off + 0] = TrackerEvent(type: .noteOn, channel: 0, instrument: 1, value1: 440) }
            if snare[r] { state.sequencerData.events[off + 1] = TrackerEvent(type: .noteOn, channel: 1, instrument: 2, value1: 440) }
        }
        timeline?.publishSnapshot()
        state.textureInvalidationTrigger += 1
        state.showStatus("Euclidean beat: kick \(pulses)/16, snare \(max(1, pulses - 2))/16")
    }

    private func lSystemArp() {
        let iterations = max(2, Int(2 + genComplexity * 4))
        let seq = LSystemGenerator.fibonacci(seed: UInt8(genKey), iterations: iterations)
        state.snapshotForUndo(label: "L-System Arp")
        let pat = state.currentPattern
        let ch  = genTargetChannel
        for (i, val) in seq.prefix(64).enumerated() {
            let f = Float(261.63 * pow(2.0, Double(val) / 12.0))
            state.sequencerData.events[(pat * 64 + i) * kMaxChannels + ch] =
                TrackerEvent(type: .noteOn, channel: UInt8(ch), instrument: 1, value1: f)
        }
        timeline?.publishSnapshot()
        state.textureInvalidationTrigger += 1
        state.showStatus("L-System arp on Ch \(ch + 1) (depth \(iterations))")
    }

    private func harmonyLayer() {
        state.snapshotForUndo(label: "Harmony Layer")
        let pat = state.currentPattern
        let interval: Float = genIntensity > 0.5 ? 1.4983 : 1.2599   // perfect 5th vs major 3rd
        for r in 0..<64 {
            let off = (pat * 64 + r) * kMaxChannels
            let ev = state.sequencerData.events[off]
            if ev.type == .noteOn {
                state.sequencerData.events[off + 2] =
                    TrackerEvent(type: .noteOn, channel: 2, instrument: ev.instrument, value1: ev.value1 * interval)
            }
        }
        timeline?.publishSnapshot()
        state.textureInvalidationTrigger += 1
        state.showStatus(genIntensity > 0.5 ? "Harmony at perfect 5th" : "Harmony at major 3rd")
    }

    private func generateBassline() {
        state.snapshotForUndo(label: "Bassline")
        let pat = state.currentPattern
        let scaleSteps = genScale.intervalsFromRoot
        let rootMidi   = 36 + genKey
        let stepLen    = max(1, Int(8 - genComplexity * 6))
        let ch = genTargetChannel
        for r in Swift.stride(from: 0, to: 64, by: stepLen) {
            let degree = Int.random(in: 0..<scaleSteps.count)
            let midi   = rootMidi + scaleSteps[degree]
            let f = Float(440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0))
            state.sequencerData.events[(pat * 64 + r) * kMaxChannels + ch] =
                TrackerEvent(type: .noteOn, channel: UInt8(ch), instrument: 2, value1: f)
        }
        timeline?.publishSnapshot()
        state.textureInvalidationTrigger += 1
        state.showStatus("Bassline in \(noteName(genKey)) \(genScale.rawValue.lowercased())")
    }

    private func generateDrumPattern() {
        state.snapshotForUndo(label: "Drum Pattern")
        let pat = state.currentPattern
        for i in 0..<64 {
            let r = i % 16
            let off = (pat * 64 + i) * kMaxChannels
            // Style-specific patterns.
            switch genStyle {
            case .techno:
                if r % 4 == 0 { state.sequencerData.events[off + 0] = TrackerEvent(type: .noteOn, channel: 0, instrument: 1, value1: 440) }
                if r == 4 || r == 12 { state.sequencerData.events[off + 1] = TrackerEvent(type: .noteOn, channel: 1, instrument: 2, value1: 440) }
                if r % 2 == 1 { state.sequencerData.events[off + 2] = TrackerEvent(type: .noteOn, channel: 2, instrument: 3, value1: 440) }
            case .dnb:
                if r == 0 || r == 10 { state.sequencerData.events[off + 0] = TrackerEvent(type: .noteOn, channel: 0, instrument: 1, value1: 440) }
                if r == 4 || r == 12 { state.sequencerData.events[off + 1] = TrackerEvent(type: .noteOn, channel: 1, instrument: 2, value1: 440) }
            case .ambient:
                if r % 8 == 0 { state.sequencerData.events[off + 0] = TrackerEvent(type: .noteOn, channel: 0, instrument: 1, value1: 220) }
            case .hiphop:
                if r == 0 || r == 8 { state.sequencerData.events[off + 0] = TrackerEvent(type: .noteOn, channel: 0, instrument: 1, value1: 440) }
                if r == 4 || r == 12 { state.sequencerData.events[off + 1] = TrackerEvent(type: .noteOn, channel: 1, instrument: 2, value1: 440) }
                if r % 2 == 1 && Bool.random() { state.sequencerData.events[off + 2] = TrackerEvent(type: .noteOn, channel: 2, instrument: 3, value1: 440) }
            case .jazz:
                if [0, 5, 10].contains(r) { state.sequencerData.events[off + 0] = TrackerEvent(type: .noteOn, channel: 0, instrument: 1, value1: 440) }
                if r == 4 || r == 12 { state.sequencerData.events[off + 1] = TrackerEvent(type: .noteOn, channel: 1, instrument: 2, value1: 440) }
            case .breakbeat:
                if [0, 6, 10].contains(r) { state.sequencerData.events[off + 0] = TrackerEvent(type: .noteOn, channel: 0, instrument: 1, value1: 440) }
                if r == 4 || r == 12 { state.sequencerData.events[off + 1] = TrackerEvent(type: .noteOn, channel: 1, instrument: 2, value1: 440) }
            }
        }
        timeline?.publishSnapshot()
        state.textureInvalidationTrigger += 1
        state.showStatus("\(genStyle.rawValue) drum pattern")
    }

    private func generateChordProgression() {
        state.snapshotForUndo(label: "Chord Progression")
        let pat = state.currentPattern
        // I–V–vi–IV in the chosen scale (degrees 0, 4, 5, 3).
        let degrees = [0, 4, 5, 3]
        let scaleSteps = genScale.intervalsFromRoot
        let rootMidi = 60 + genKey
        for chordIdx in 0..<4 {
            let beatStart = chordIdx * 16
            let degree = degrees[chordIdx]
            let chordRoot = rootMidi + scaleSteps[degree % scaleSteps.count]
            let chord = [chordRoot, chordRoot + 4, chordRoot + 7]    // major triad
            for (offset, midi) in chord.enumerated() {
                let off = (pat * 64 + beatStart) * kMaxChannels + offset + 4
                let f = Float(440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0))
                state.sequencerData.events[off] =
                    TrackerEvent(type: .noteOn, channel: UInt8(offset + 4), instrument: 1, value1: f)
            }
        }
        timeline?.publishSnapshot()
        state.textureInvalidationTrigger += 1
        state.showStatus("I–V–vi–IV in \(noteName(genKey)) \(genScale.rawValue.lowercased())")
    }

    private func generateVariation() {
        state.snapshotForUndo(label: "Variation")
        let pat = state.currentPattern
        let amount = Float(genIntensity)
        for r in 0..<64 {
            for ch in 0..<kMaxChannels {
                let off = (pat * 64 + r) * kMaxChannels + ch
                let ev = state.sequencerData.events[off]
                if ev.type == .noteOn, Float.random(in: 0..<1) < amount * 0.4 {
                    let detune: Float = [0.95, 1.05, 1.122, 0.891].randomElement()!
                    state.sequencerData.events[off].value1 = ev.value1 * detune
                }
            }
        }
        timeline?.publishSnapshot()
        state.textureInvalidationTrigger += 1
        state.showStatus("Variation @ \(Int(genIntensity * 100))% intensity")
    }

    private func noteName(_ k: Int) -> String {
        ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"][k % 12]
    }
}

// MARK: - Generative style + scale enums

public enum GenerativeStyle: String, CaseIterable, Sendable {
    case techno    = "Techno"
    case dnb       = "Drum & Bass"
    case ambient   = "Ambient"
    case hiphop    = "Hip-Hop"
    case jazz      = "Jazz"
    case breakbeat = "Breakbeat"
}

public enum ScaleKind: String, CaseIterable, Sendable {
    case major      = "Major"
    case minor      = "Minor"
    case dorian     = "Dorian"
    case phrygian   = "Phrygian"
    case lydian     = "Lydian"
    case mixolydian = "Mixolydian"
    case pentatonic = "Pentatonic"
    case blues      = "Blues"

    /// Semitone offsets from the root for the first octave.
    public var intervalsFromRoot: [Int] {
        switch self {
        case .major:      return [0, 2, 4, 5, 7, 9, 11]
        case .minor:      return [0, 2, 3, 5, 7, 8, 10]
        case .dorian:     return [0, 2, 3, 5, 7, 9, 10]
        case .phrygian:   return [0, 1, 3, 5, 7, 8, 10]
        case .lydian:     return [0, 2, 4, 6, 7, 9, 11]
        case .mixolydian: return [0, 2, 4, 5, 7, 9, 10]
        case .pentatonic: return [0, 2, 4, 7, 9]
        case .blues:      return [0, 3, 5, 6, 7, 10]
        }
    }
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
