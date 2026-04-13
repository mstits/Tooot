/*
 *  PROJECT ToooT (ToooT_UI)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  Plugin UI Dialogs mapping to Offline DSP and Pattern Modifiers.
 */

import SwiftUI
import ToooT_Core
import ToooT_Plugins
import AVFoundation
import ToooT_VST3

@MainActor
public struct PluginDialogContainer: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    let pluginType: PluginType
    
    public var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(pluginType.rawValue.capitalized).font(.headline)
                Spacer()
                Button("Close") { state.activePluginDialog = nil }
            }.padding(.bottom, 10)
            Divider()
            switch pluginType {
            case .amplitude: AmplitudeDialog(state: state, timeline: timeline)
            case .toneGenerator: ToneGeneratorDialog(state: state, timeline: timeline)
            case .echo: EchoDialog(state: state, timeline: timeline)
            case .fade: FadeDialog(state: state, timeline: timeline)
            case .depth: DepthDialog(state: state, timeline: timeline)
            case .noteTranslate: NoteTranslateDialog(state: state, timeline: timeline)
            case .fadeNote: FadeNoteDialog(state: state, timeline: timeline)
            case .fadeVolume: FadeVolumeDialog(state: state, timeline: timeline)
            case .complexFade: ComplexFadeDialog(state: state, timeline: timeline)
            case .propagate: PropagateDialog(state: state, timeline: timeline)
            case .revert: RevertDialog(state: state, timeline: timeline)
            case .crop: CropDialog(state: state, timeline: timeline)
            case .crossfade: CrossfadeDialog(state: state, timeline: timeline)
            case .mix: MixDialog(state: state, timeline: timeline)
            case .samplingRate, .length: ResampleDialog(state: state, timeline: timeline)
            case .normalize, .invert, .silence, .backwards, .smooth:
                SimpleActionDialog(state: state, timeline: timeline, actionType: pluginType)
            case .importMIDI, .importClassicApp, .ioAIFF, .ioWave, .ioXI, .ioPAT, .ioMINs, .ioSys7, .ioQuickTime:
                IODialog(state: state, timeline: timeline, actionType: pluginType)
            case .externalInstrument:
                ExternalInstrumentDialog(state: state, timeline: timeline)
            }
        }
        .padding().frame(width: 400, height: 400).background(StudioTheme.background)
    }
}

@MainActor
struct ExternalInstrumentDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    
    @State private var isLoading = false
    @State private var vst3Plugins: [String] = []
    @State private var searchText = ""
    @State private var filterNI = false
    
    var body: some View {
        let auInstruments = timeline?.hostManager.availablePlugins.filter { $0.audioComponentDescription.componentType == kAudioUnitType_MusicDevice } ?? []
        let filteredAU = auInstruments.filter { comp in
            let matchesSearch = searchText.isEmpty || comp.name.localizedCaseInsensitiveContains(searchText) || comp.manufacturerName.localizedCaseInsensitiveContains(searchText)
            let isNI = comp.manufacturerName.localizedCaseInsensitiveContains("Native Instruments") || comp.name.localizedCaseInsensitiveContains("Kontakt") || comp.name.localizedCaseInsensitiveContains("Massive")
            return matchesSearch && (!filterNI || isNI)
        }
        
        let filteredVST = vst3Plugins.filter { path in
            let name = (path as NSString).lastPathComponent
            let matchesSearch = searchText.isEmpty || name.localizedCaseInsensitiveContains(searchText)
            let isNI = name.localizedCaseInsensitiveContains("Native Instruments") || name.localizedCaseInsensitiveContains("Kontakt") || name.localizedCaseInsensitiveContains("Massive")
            return matchesSearch && (!filterNI || isNI)
        }

        return VStack(spacing: 16) {
            // Header with Search and Filter
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.gray)
                    TextField("Search instruments...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                    
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
                
                HStack {
                    FilterChip(label: "ALL", isActive: !filterNI) { filterNI = false }
                    FilterChip(label: "NATIVE INSTRUMENTS", isActive: filterNI) { filterNI = true }
                    Spacer()
                }
            }
            
            ScrollView {
                VStack(spacing: 12) {
                    // AUv3 Section
                    if !filteredAU.isEmpty {
                        PluginSectionHeader(title: "AUv3 PLUGINS", icon: "apple.logo")
                        ForEach(filteredAU, id: \.name) { comp in
                            InstrumentRow(name: comp.name, manufacturer: comp.manufacturerName, type: "AUv3") {
                                loadAU(comp)
                            }
                        }
                    }
                    
                    // VST3 Section
                    if !filteredVST.isEmpty {
                        PluginSectionHeader(title: "VST3 PLUGINS (JUCE)", icon: "pianokeys")
                        ForEach(filteredVST, id: \.self) { path in
                            InstrumentRow(name: (path as NSString).lastPathComponent, manufacturer: "Steinberg/NI", type: "VST3") {
                                loadVST3(path)
                            }
                        }
                    }
                    
                    if filteredAU.isEmpty && filteredVST.isEmpty {
                        VStack(spacing: 20) {
                            Spacer()
                            Image(systemName: "music.note.list").font(.system(size: 40)).opacity(0.2)
                            Text(filterNI ? "No Native Instruments found on this system." : "No instruments found matching your criteria.")
                                .font(.caption).opacity(0.5)
                            Spacer()
                        }.frame(height: 200)
                    }
                }
            }
            .frame(height: 250)
            
            if isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Initializing Engine...").font(.system(size: 9, design: .monospaced)).foregroundColor(.gray)
                }
            }
            
            Text("HOSTING ON CHANNEL \(state.selectedChannel + 1)").font(.system(size: 8, weight: .black)).foregroundColor(.orange.opacity(0.8))
        }
        .onAppear {
            vst3Plugins = JUCEVST3Host.discoverPlugins()
        }
    }
    
    private func loadAU(_ component: AVAudioUnitComponent) {
        isLoading = true
        Task {
            NotificationCenter.default.post(name: NSNotification.Name("LoadExternalPlugin"), object: (component.audioComponentDescription, state.selectedChannel))
            try? await Task.sleep(nanoseconds: 800_000_000)
            isLoading = false
            state.activePluginDialog = nil
            state.showStatus("LOADED: \(component.name)")
        }
    }
    
    private func loadVST3(_ path: String) {
        isLoading = true
        Task {
            NotificationCenter.default.post(name: NSNotification.Name("LoadVST3Plugin"), object: (path, state.selectedChannel))
            try? await Task.sleep(nanoseconds: 800_000_000)
            isLoading = false
            state.activePluginDialog = nil
            state.showStatus("LOADED VST3: \((path as NSString).lastPathComponent)")
        }
    }
}

struct FilterChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 8, weight: .black))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(isActive ? Color.purple : Color.white.opacity(0.1))
                .foregroundColor(isActive ? .white : .gray)
                .cornerRadius(4)
        }.buttonStyle(.plain)
    }
}

struct PluginSectionHeader: View {
    let title: String
    let icon: String
    var body: some View {
        HStack {
            Image(systemName: icon).font(.system(size: 8))
            Text(title).font(.system(size: 8, weight: .black))
            Spacer()
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
        }.foregroundColor(.gray).padding(.top, 4)
    }
}

struct InstrumentRow: View {
    let name: String
    let manufacturer: String
    let type: String
    let action: () -> Void
    @State private var isHovering = false
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 11, weight: .bold, design: .monospaced))
                    Text(manufacturer.uppercased()).font(.system(size: 7, weight: .medium)).opacity(0.6)
                }
                Spacer()
                Text(type).font(.system(size: 7, weight: .black)).padding(4).background(Color.black.opacity(0.4)).cornerRadius(3).opacity(0.8)
            }
            .padding(10)
            .background(isHovering ? Color.purple.opacity(0.2) : Color.white.opacity(0.03))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isHovering ? Color.purple.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

@MainActor
struct SimpleActionDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    let actionType: PluginType
    var body: some View {
        VStack {
            Text("Apply \(actionType.rawValue.capitalized)?")
            Button("Apply to Current Instrument") {
                if let bank = timeline?.audioEngine?.sampleBank {
                    let reg = state.instruments[state.selectedInstrument]?.regions.0
                    let off = reg?.offset ?? 0; let len = reg?.length ?? 0
                    // Snapshot before mutating — enables UNDO DSP in Waveform Forge
                    state.snapshotDSPUndo(bank: bank, offset: off, length: len, instrument: state.selectedInstrument)
                    switch actionType {
                    case .normalize: OfflineDSP.normalize(bank: bank, offset: off, length: len)
                    case .invert:    OfflineDSP.invert(bank: bank, offset: off, length: len)
                    case .silence:   OfflineDSP.silence(bank: bank, offset: off, length: len)
                    case .backwards: OfflineDSP.backwards(bank: bank, offset: off, length: len)
                    case .smooth:    OfflineDSP.smooth(bank: bank, offset: off, length: len)
                    default: break
                    }
                    state.textureInvalidationTrigger += 1
                    state.activePluginDialog = nil
                    state.showStatus("Applied \(actionType.rawValue.capitalized) — UNDO DSP available")
                }
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct AmplitudeDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    @State private var percentage: Float = 100.0
    var body: some View {
        VStack {
            Text("Adjust Volume Percentage")
            Slider(value: $percentage, in: 0...200)
            Text("\(Int(percentage))%")
            Button("Apply to Current Instrument") {
                if let bank = timeline?.audioEngine?.sampleBank {
                    OfflineDSP.amplitude(bank: bank, offset: state.instruments[state.selectedInstrument]?.regions.0.offset ?? 0, length: state.instruments[state.selectedInstrument]?.regions.0.length ?? 0, percentage: percentage)
                    state.textureInvalidationTrigger += 1
                    state.activePluginDialog = nil
                }
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct EchoDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    @State private var delayMs: Float = 300.0
    @State private var feedback: Float = 0.5
    var body: some View {
        VStack {
            Text("Delay (ms): \(Int(delayMs))"); Slider(value: $delayMs, in: 10...1000)
            Text("Feedback: \(String(format: "%.2f", feedback))"); Slider(value: $feedback, in: 0...0.99)
            Button("Apply to Current Instrument") {
                if let bank = timeline?.audioEngine?.sampleBank {
                    let delaySamples = Int((delayMs / 1000.0) * 44100.0)
                    OfflineDSP.echo(bank: bank, offset: state.instruments[state.selectedInstrument]?.regions.0.offset ?? 0, length: state.instruments[state.selectedInstrument]?.regions.0.length ?? 0, delaySamples: delaySamples, feedback: feedback)
                    state.textureInvalidationTrigger += 1
                    state.activePluginDialog = nil
                }
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct ToneGeneratorDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    @State private var frequency: Float = 440.0
    @State private var waveType: OfflineDSP.WaveType = .sine
    var body: some View {
        VStack {
            Text("Frequency (Hz): \(Int(frequency))"); Slider(value: $frequency, in: 20...5000)
            Picker("Waveform", selection: $waveType) {
                Text("Sine").tag(OfflineDSP.WaveType.sine)
                Text("Square").tag(OfflineDSP.WaveType.square)
                Text("Saw").tag(OfflineDSP.WaveType.saw)
                Text("Tri").tag(OfflineDSP.WaveType.triangle)
            }.pickerStyle(.segmented)
            Button("Generate in Current Instrument") {
                if let bank = timeline?.audioEngine?.sampleBank {
                    let targetLength = 44100 * 2
                    var targetOffset = 0
                    if let inst = state.instruments[state.selectedInstrument], inst.regionCount > 0 {
                        targetOffset = inst.regions.0.offset
                    } else {
                        targetOffset = state.instruments.values.reduce(0) { max($0, $1.regionCount > 0 ? $1.regions.0.offset + $1.regions.0.length : 0) }
                    }
                    OfflineDSP.generateTone(bank: bank, offset: targetOffset, length: targetLength, frequency: frequency, type: waveType)
                    var inst = state.instruments[state.selectedInstrument] ?? Instrument()
                    inst.nameString = "Tone \(Int(frequency))Hz"
                    inst.setSingleRegion(SampleRegion(offset: targetOffset, length: targetLength))
                    state.instruments[state.selectedInstrument] = inst
                    timeline?.publishSnapshot()
                    state.textureInvalidationTrigger += 1
                    state.activePluginDialog = nil
                }
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct FadeDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    @State private var isFadeIn: Bool = true
    var body: some View {
        VStack {
            Picker("Direction", selection: $isFadeIn) { Text("Fade In").tag(true); Text("Fade Out").tag(false) }.pickerStyle(.segmented)
            Button("Apply to Current Instrument") {
                if let bank = timeline?.audioEngine?.sampleBank {
                    OfflineDSP.fade(bank: bank, offset: state.instruments[state.selectedInstrument]?.regions.0.offset ?? 0, length: state.instruments[state.selectedInstrument]?.regions.0.length ?? 0, isFadeIn: isFadeIn)
                    state.textureInvalidationTrigger += 1
                    state.activePluginDialog = nil
                }
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct DepthDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    @State private var bits: Float = 8.0
    var body: some View {
        VStack {
            Text("Bit Depth: \(Int(bits))"); Slider(value: $bits, in: 2...16, step: 1)
            Button("Apply to Current Instrument") {
                if let bank = timeline?.audioEngine?.sampleBank {
                    OfflineDSP.depth(bank: bank, offset: state.instruments[state.selectedInstrument]?.regions.0.offset ?? 0, length: state.instruments[state.selectedInstrument]?.regions.0.length ?? 0, bits: Int(bits))
                    state.textureInvalidationTrigger += 1
                    state.activePluginDialog = nil
                }
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct NoteTranslateDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    @State private var semitones: Float = 12.0
    var body: some View {
        VStack {
            Text("Shift Semitones: \(Int(semitones))"); Slider(value: $semitones, in: -24...24, step: 1)
            Button("Apply to Entire Pattern") {
                PatternDSP.noteTranslate(snapshot: state.sequencerData.events, startRow: state.currentPattern * 64, endRow: (state.currentPattern * 64) + 63, semitones: semitones)
                timeline?.publishSnapshot()
                state.textureInvalidationTrigger += 1
                state.activePluginDialog = nil
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct FadeVolumeDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    @State private var startVolume: Float = 0.0
    @State private var endVolume: Float = 1.0
    var body: some View {
        VStack {
            Text("Start Volume: \(Int(startVolume * 100))%"); Slider(value: $startVolume, in: 0...1.0)
            Text("End Volume: \(Int(endVolume * 100))%"); Slider(value: $endVolume, in: 0...1.0)
            Button("Apply to Current Pattern") {
                PatternDSP.fadeVolume(snapshot: state.sequencerData.events, startRow: state.currentPattern * 64, endRow: (state.currentPattern * 64) + 63, startVolume: startVolume, endVolume: endVolume)
                timeline?.publishSnapshot()
                state.textureInvalidationTrigger += 1
                state.activePluginDialog = nil
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct FadeNoteDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    @State private var startFreq: Float = 440.0
    @State private var endFreq: Float = 880.0
    var body: some View {
        VStack {
            Text("Start Freq: \(Int(startFreq)) Hz"); Slider(value: $startFreq, in: 20...5000)
            Text("End Freq: \(Int(endFreq)) Hz"); Slider(value: $endFreq, in: 20...5000)
            Button("Apply to Current Pattern") {
                PatternDSP.fadeNote(snapshot: state.sequencerData.events, startRow: state.currentPattern * 64, endRow: (state.currentPattern * 64) + 63, startFrequency: startFreq, endFrequency: endFreq, instrument: UInt8(state.selectedInstrument), channel: UInt8(state.cursorX))
                timeline?.publishSnapshot()
                state.textureInvalidationTrigger += 1
                state.activePluginDialog = nil
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct ComplexFadeDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    @State private var startVol: Float = 0.0
    @State private var endVol: Float = 1.0
    @State private var startFreq: Float = 440.0
    @State private var endFreq: Float = 880.0
    var body: some View {
        VStack {
            HStack {
                VStack { Text("Start Vol: \(Int(startVol * 100))%"); Slider(value: $startVol, in: 0...1.0)
                         Text("End Vol: \(Int(endVol * 100))%"); Slider(value: $endVol, in: 0...1.0) }
                VStack { Text("Start Freq: \(Int(startFreq))"); Slider(value: $startFreq, in: 20...5000)
                         Text("End Freq: \(Int(endFreq))"); Slider(value: $endFreq, in: 20...5000) }
            }
            Button("Apply Complex Fade") {
                let sRow = state.currentPattern * 64, eRow = sRow + 63, ch = UInt8(state.cursorX)
                PatternDSP.fadeVolume(snapshot: state.sequencerData.events, startRow: sRow, endRow: eRow, startVolume: startVol, endVolume: endVol, channel: ch)
                PatternDSP.fadeNote(snapshot: state.sequencerData.events, startRow: sRow, endRow: eRow, startFrequency: startFreq, endFrequency: endFreq, instrument: UInt8(state.selectedInstrument), channel: ch)
                timeline?.publishSnapshot()
                state.textureInvalidationTrigger += 1
                state.activePluginDialog = nil
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct PropagateDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    var body: some View {
        VStack {
            Text("Propagate Row 0 to Entire Pattern?")
            Button("Apply to Current Pattern") {
                PatternDSP.propagate(snapshot: state.sequencerData.events, startRow: state.currentPattern * 64, endRow: (state.currentPattern * 64) + 63)
                timeline?.publishSnapshot()
                state.textureInvalidationTrigger += 1
                state.activePluginDialog = nil
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct RevertDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    var body: some View {
        VStack {
            Text("Revert (Reverse) Current Pattern?")
            Button("Apply to Current Pattern") {
                PatternDSP.revert(snapshot: state.sequencerData.events, startRow: state.currentPattern * 64, endRow: (state.currentPattern * 64) + 63)
                timeline?.publishSnapshot()
                state.textureInvalidationTrigger += 1
                state.activePluginDialog = nil
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct CropDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    @State private var startPct: Float = 0.0
    @State private var endPct: Float = 1.0
    var body: some View {
        VStack {
            Text("Start Point: \(Int(startPct * 100))%"); Slider(value: $startPct, in: 0...0.99)
            Text("End Point: \(Int(endPct * 100))%"); Slider(value: $endPct, in: 0.01...1.0)
            Button("Apply Crop to Instrument") {
                if let bank = timeline?.audioEngine?.sampleBank {
                    let newLen = OfflineDSP.crop(bank: bank, offset: state.instruments[state.selectedInstrument]?.regions.0.offset ?? 0, length: state.instruments[state.selectedInstrument]?.regions.0.length ?? 0, startPercent: startPct, endPercent: endPct)
                    if var inst = state.instruments[state.selectedInstrument], inst.regionCount > 0 {
                        var reg = inst.regions.0
                        reg.length = newLen
                        inst.setSingleRegion(reg)
                        state.instruments[state.selectedInstrument] = inst
                    }
                    timeline?.publishSnapshot()
                    state.textureInvalidationTrigger += 1
                    state.activePluginDialog = nil
                }
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct CrossfadeDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    var body: some View {
        VStack {
            Text("Crossfade Loop Points")
            Button("Apply Crossfade") {
                if let bank = timeline?.audioEngine?.sampleBank, let inst = state.instruments[state.selectedInstrument], inst.regionCount > 0 {
                    let region = inst.regions.0
                    if region.loopType != .none && region.loopLength > 0 {
                        OfflineDSP.crossfade(bank: bank, offset: state.instruments[state.selectedInstrument]?.regions.0.offset ?? 0, length: state.instruments[state.selectedInstrument]?.regions.0.length ?? 0, loopStart: region.loopStart, loopLength: region.loopLength)
                        state.textureInvalidationTrigger += 1
                    }
                    state.activePluginDialog = nil
                }
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct MixDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    @State private var mixTarget: Float = 2
    @State private var mixRatio: Float = 0.5
    var body: some View {
        VStack {
            Text("Mix Target Instrument: \(String(format: "%02X", Int(mixTarget)))"); Slider(value: $mixTarget, in: 1...255, step: 1)
            Text("Ratio: \(Int(mixRatio * 100))%"); Slider(value: $mixRatio, in: 0...1.0)
            Button("Mix Instruments") {
                if let bank = timeline?.audioEngine?.sampleBank {
                    OfflineDSP.mix(bank: bank, offset1: state.instruments[state.selectedInstrument]?.regions.0.offset ?? 0, offset2: state.instruments[Int(mixTarget)]?.regions.0.offset ?? 0, length: state.instruments[state.selectedInstrument]?.regions.0.length ?? 0, mixRatio: mixRatio)
                    state.textureInvalidationTrigger += 1
                    state.activePluginDialog = nil
                }
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct ResampleDialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    @State private var factor: Float = 2.0
    var body: some View {
        VStack {
            Text("Resample Factor: \(String(format: "%.2f", factor))x"); Slider(value: $factor, in: 0.1...4.0)
            Button("Apply Resampling") {
                if let bank = timeline?.audioEngine?.sampleBank {
                    let newLen = OfflineDSP.resample(bank: bank, offset: state.instruments[state.selectedInstrument]?.regions.0.offset ?? 0, length: state.instruments[state.selectedInstrument]?.regions.0.length ?? 0, factor: factor)
                    if var inst = state.instruments[state.selectedInstrument], inst.regionCount > 0 {
                        var reg = inst.regions.0
                        reg.length = newLen
                        inst.setSingleRegion(reg)
                        state.instruments[state.selectedInstrument] = inst
                    }
                    timeline?.publishSnapshot()
                    state.textureInvalidationTrigger += 1
                    state.activePluginDialog = nil
                }
            }.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct IODialog: View {
    @Bindable var state: PlaybackState
    let timeline: Timeline?
    let actionType: PluginType

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.largeTitle).foregroundColor(.purple)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundColor(.gray).multilineTextAlignment(.center)
            Button(buttonLabel) { execute() }.buttonStyle(.borderedProminent)
        }
    }

    private var icon: String {
        switch actionType {
        case .importMIDI:        return "pianokeys"
        case .importClassicApp:  return "doc.on.doc"
        case .ioAIFF, .ioWave:   return "waveform"
        case .ioXI, .ioPAT, .ioMINs, .ioSys7: return "music.note.list"
        case .ioQuickTime:       return "film"
        default:                 return "doc.zipper"
        }
    }

    private var title: String {
        switch actionType {
        case .importMIDI:        return "Import MIDI File"
        case .importClassicApp:  return "Import Classic Tracker File"
        case .ioAIFF:            return "Load AIFF Sample"
        case .ioWave:            return "Load WAVE Sample"
        case .ioXI:              return "Load FastTracker XI Instrument"
        case .ioPAT:             return "Load Gravis PAT Sample"
        case .ioMINs:            return "Load LegacyTracker MIN Sample"
        case .ioSys7:            return "Load System 7 Sound"
        case .ioQuickTime:       return "Load Audio from Movie"
        default:                 return actionType.rawValue.capitalized
        }
    }

    private var subtitle: String {
        switch actionType {
        case .importMIDI:        return "Parse note events from a Standard MIDI File (.mid) into the current pattern."
        case .importClassicApp:  return "Load a .mod, .mad, .xm or .it file as the current song."
        case .ioAIFF, .ioWave, .ioXI, .ioPAT, .ioMINs, .ioSys7:
            return "Loads the file into the currently selected instrument slot (\(state.selectedInstrument))."
        case .ioQuickTime:
            return "Extracts the audio track from a QuickTime movie and loads it into the selected instrument slot."
        default: return ""
        }
    }

    private var buttonLabel: String {
        switch actionType {
        case .importMIDI, .importClassicApp: return "Choose File…"
        default: return "Choose Audio File…"
        }
    }

    private func execute() {
        switch actionType {
        case .importMIDI: chooseMIDI()
        case .importClassicApp: chooseTrackerFile()
        case .ioAIFF, .ioWave, .ioXI, .ioPAT, .ioMINs, .ioSys7, .ioQuickTime: chooseAudioFile()
        default: state.activePluginDialog = nil
        }
    }

    private func chooseMIDI() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.midi]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { importMIDI(from: url); state.activePluginDialog = nil }
    }

    private func chooseTrackerFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.item]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { state.activePluginDialog = nil; NotificationCenter.default.post(name: NSNotification.Name("LoadModFileURL"), object: url) }
    }

    private func chooseAudioFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { state.activePluginDialog = nil; NotificationCenter.default.post(name: NSNotification.Name("LoadInstrumentFile"), object: url) }
    }

    private func importMIDI(from url: URL) {
        guard let data = try? Data(contentsOf: url), data.count >= 14, String(bytes: data[0..<4], encoding: .ascii) == "MThd" else {
            state.showStatus("Invalid MIDI file"); return
        }
        let ticksPerQN = max(1, Int(data[12]) << 8 | Int(data[13]))
        var offset = 14; var noteCounts = 0; var maxChannelUsed = 0
        while offset + 8 <= data.count {
            guard String(bytes: data[offset..<offset+4], encoding: .ascii) == "MTrk" else {
                let skip = Int(data[offset+4]) << 24 | Int(data[offset+5]) << 16 | Int(data[offset+6]) << 8  | Int(data[offset+7]); offset += 8 + skip; continue
            }
            let chunkLen = Int(data[offset+4]) << 24 | Int(data[offset+5]) << 16 | Int(data[offset+6]) << 8  | Int(data[offset+7]); offset += 8
            let trackEnd = min(offset + chunkLen, data.count); var tick = 0; var runningStatus: UInt8 = 0
            while offset < trackEnd {
                var delta = 0; while offset < trackEnd { let b = Int(data[offset]); offset += 1; delta = (delta << 7) | (b & 0x7F); if b & 0x80 == 0 { break } }
                tick += delta; guard offset < trackEnd else { break }
                var statusByte = data[offset]; if statusByte & 0x80 != 0 { runningStatus = statusByte; offset += 1 } else { statusByte = runningStatus }
                let cmd = statusByte & 0xF0
                switch cmd {
                case 0x90 where offset + 1 < trackEnd:
                    let note = data[offset]; let vel = data[offset+1]; offset += 2
                    if vel > 0 {
                        let row = tick / max(1, ticksPerQN / 4)
                        if row < 64 * 100 {
                            var foundChannel = -1
                            for ch in 0..<kMaxChannels {
                                let idx = ((row / 64) * 64 + (row % 64)) * kMaxChannels + ch
                                if state.sequencerData.events[idx].type == .empty {
                                    foundChannel = ch; break
                                }
                            }
                            if foundChannel != -1 {
                                let idx = ((row / 64) * 64 + (row % 64)) * kMaxChannels + foundChannel
                                let freq = 440.0 * pow(2.0, (Float(note) - 69.0) / 12.0)
                                state.sequencerData.events[idx] = TrackerEvent(type: .noteOn, channel: UInt8(clamping: foundChannel), instrument: 1, value1: freq, value2: Float(vel) / 127.0, effectCommand: 0, effectParam: 0)
                                noteCounts += 1; maxChannelUsed = max(maxChannelUsed, foundChannel + 1)
                            }
                        }
                    }
                case 0x80 where offset + 1 < trackEnd, 0xA0 where offset + 1 < trackEnd, 0xB0 where offset + 1 < trackEnd, 0xE0 where offset + 1 < trackEnd: offset += 2
                case 0xC0 where offset < trackEnd, 0xD0 where offset < trackEnd: offset += 1
                case 0xFF where offset < trackEnd:
                    offset += 1; var metaLen = 0
                    while offset < trackEnd { let b = Int(data[offset]); offset += 1; metaLen = (metaLen << 7) | (b & 0x7F); if b & 0x80 == 0 { break } }
                    offset += metaLen
                case 0xF0, 0xF7: while offset < trackEnd && data[offset] != 0xF7 { offset += 1 }; if offset < trackEnd { offset += 1 }
                default: break
                }
            }
            offset = trackEnd
        }
        state.textureInvalidationTrigger += 1; timeline?.publishSnapshot()
        state.showStatus("MIDI imported — \(noteCounts) notes across \(maxChannelUsed) channels")
    }
}
