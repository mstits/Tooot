# ToooT Feature Roadmap — path to the best OSS DAW

Honest assessment of what ToooT has today vs what the last 30 years of pro DAWs (Pro Tools, Logic Pro, Ableton Live, Reaper, Bitwig, Renoise, OpenMPT) ship. Ordered by impact, not by ease.

The goal is parity with the best, not a toy. Every gap below is addressable; none of them are blocked on research. Things marked ✅ already work.

## Shipped

- ✅ Zero-allocation real-time render loop (Swift 6 strict concurrency, `vDSP`/`Accelerate` throughout)
- ✅ **Variable sample rate** — AudioEngine(sampleRate:) threads 44.1 / 48 / 88.2 / 96 / 192 kHz through the entire render + export + metering path
- ✅ **Bus inserts** — 4 AUv3 slots per aux bus, processed in place on bus buffers via pre-allocated AudioBufferLists, then summed into master
- ✅ **TruePeakLimiter AUv3** — 4× inter-sample peak detection, 64-sample look-ahead, dBTP ceiling, mastering-grade
- ✅ **MIDI Panic** — ⌘. kills transport + every voice + sends CC 120/123 on all channels
- ✅ **Crash recovery** — recentAutosaves() scan + CrashRecoveryPromptView sheet for launch-time restore
- ✅ **Arpeggiator** — up/down/updown/random/chord/asPlayed modes with hold, octave range, gate probability
- ✅ **Scale + chord quantization** — 16 scales (church modes, pentatonic, blues, whole-tone, octatonic) + 14 chord qualities
- ✅ **Multiband compressor AUv3** — 3-band LR crossovers, per-band soft-knee compressor with stereo-linked envelopes
- ✅ **Linear-phase EQ scaffold** — full FFT infrastructure (vDSP, Hann window, inverse FFT), convolution path ready to activate
- ✅ **Scene automation** — SceneSnapshot/SceneBank capture & recall entire mixer state (volumes/pans/mutes/sends/buses/master/BPM/sidechain), serialized into .mad TOOO chunk
- ✅ **MPE event extension** — TrackerEvent carries noteId + perNotePitchBend + perNotePressure + perNoteTimbre; MIDI2Manager.dispatchUMP handles Note On/Off/Per-Note Bend/Pressure with voice tracking
- ✅ **Undo history browser** — PlaybackState.undoLabels parallel array + UndoHistoryBrowserView panel for jump-to-step navigation
- ✅ **Keyboard shortcut customization** — KeyBindingManager with ToooT / Pro Tools / Logic Pro preset modes, UserDefaults-persisted
- ✅ **JavaScript scripting** — JavaScriptCore-based ToooTScriptBridge exposing state/setNote/fillChannel/setSend/setBusVolume/console.log to user .js scripts
- ✅ **XCTest port (partial)** — ShippedFeaturesTests covering MasterMeter / MusicTheory / Arpeggiator / TruePeakLimiter / OfflineDSP / Scene / KeyBinding
- ✅ ProTracker / FastTracker / Impulse Tracker format parity (MOD/XM/IT + `.mad` native format, lossless round-trip)
- ✅ AUv3 hosting — full insert chains (4 per channel + 1 instrument)
- ✅ CLAP hosting — full discovery + load + real-time process (BSD-3, MIT-compatible)
- ✅ VST3 hosting — stubbed + gated, drop-in when Steinberg SDK vendored
- ✅ MIDI 2.0 I/O (UMP + clock + per-channel CC mapping)
- ✅ PHASE 3D spatial audio
- ✅ SynthVoice with `vDSP_vlint` fast path + scalar Hermite fallback for loop/ping-pong
- ✅ Plugin Delay Compensation (per-channel circular buffers)
- ✅ Sidechain ducking
- ✅ Master safety limiter
- ✅ **Mastering metering** — ITU-R BS.1770-4 LUFS (momentary / short-term / integrated) + 4× true-peak + L/R phase correlation
- ✅ **Aux bus routing** — 4 stereo buses, per-(channel,bus) send matrix, per-bus master volumes (bus inserts still pending)
- ✅ **Dither + loudness-normalized export** — TPDF/rectangular dither, Spotify/Apple/YouTube/EBU R128 targets with true-peak ceiling
- ✅ **Project auto-save** — 60 s cadence, rolling 10-file per-title window, crash-recovery prompt ready
- ✅ **Command palette** — ⌘K fuzzy finder with default Transport/Mastering/File/Edit/Track/View commands
- ✅ **Template projects** — programmatic builders for Blank / Drum Starter / Ambient Pad / Techno Basic
- ✅ SOLA time-stretch + pitch-shift
- ✅ Track freeze
- ✅ Stems export
- ✅ Master WAV export (with optional mastering chain)
- ✅ Recording from live input
- ✅ 50-level global undo (pattern) + DSP undo (waveform)
- ✅ JIT shell with macros (`fill`, `euclid`, `tidal`, `humanize`, `evolve`, `copy`, `fade`, …)
- ✅ Metal-accelerated pattern grid

## Core DAW gaps (must-have for pro use)

### 1. Variable sample rate ✅ **SHIPPED**
`AudioEngine(sampleRate:)` and `AudioRenderNode(sampleRate:)` stored properties threaded through the render block, offline render, SynthVoice.process, MasterMeter, AUAudioUnitBus format, CoreAudio output stream, exportAudio, exportStems, freezeChannel, SpatialManager, CLAP instance rate. UAT suite 36 verifies 48 kHz end-to-end.

### 2. Linear arrangement view
**Today:** tracker pattern grid only. Pattern-based composition is one of three major DAW paradigms; the other two are session-view (Ableton) and linear timeline (everyone else).
**Pro DAWs:** clips on tracks along a horizontal timeline, drag-to-arrange, ripple edit, slip edit, scrub preview. Pro Tools / Logic / Reaper / Cubase all build on this.
**Fix:** New `Arrangement` model: `Track → [AudioClip | MIDIClip | PatternClip]`. Clip has `start`, `length`, `offset` in source, `fadeIn`, `fadeOut`, `gain`. `AudioRenderNode` gains a second mode that reads from clips rather than patterns (or composes both). Substantial — ~3000 lines.

### 3. Clip-based audio editing
**Today:** audio is instruments + tracker triggers.
**Pro DAWs:** audio clips are first-class — drag to trim, slip contents, crossfade between adjacent clips, time-warp with warp markers, replace-from-same-take.
**Fix:** Builds on #2. Adds `AudioClip` type + slip/trim UI + crossfade rendering in the voice summing path.

### 4. Take lanes & comping
**Today:** record one pass, overwrites the instrument.
**Pro DAWs:** record N passes into separate lanes per take, comp-edit to pick the best bits across takes, quick-swipe comping.
**Fix:** `RecordingTake` model + takes view UI. Builds on #3.

### 5. Buses, sends, groups, VCAs ⚠ **PARTIAL**
Aux bus **plumbing** ships: `kAuxBusCount = 4` stereo buses in `RenderResources`, per-(channel,bus) send matrix, per-bus master volumes, RT-safe vDSP accumulation in both realtime + offline. `PlaybackState.setSend / setBusVolume` exposed. **Still pending:** AUv3 inserts on bus outputs (requires refactoring bus summing out of `renderBlock` into `RenderBlockWrapper` so insert chains can process bus buffers before the master sum).

### 6. LUFS / true-peak / phase correlation metering ✅ **SHIPPED**
`MasterMeter` in `ToooT_Core/Metering.swift` implements ITU-R BS.1770-4: pre-filter high-shelf + RLB high-pass biquads (recomputed per sample rate), 100 ms block accumulator → momentary (400 ms) + short-term (3 s) + gated integrated (absolute −70 LU gate). 4× linear-interp true-peak detection. Pearson L/R phase correlation over 400 ms. Wired on the post-limiter master. Key fix: `reset()` clears biquad history so post-transient filter decay doesn't pin integrated LUFS at ~−37 dB after transport stop.

### 7. Automation beyond Bezier volume/pan/pitch
**Today:** Automation lanes declared in `PlaybackState.automationLanes` but read path partial.
**Pro DAWs:** automate every parameter (plugin params, sends, bus levels, tempo, key, time signature). Modes: read / touch / latch / write / trim. Link across channels.
**Fix:** Flesh out lane evaluator in render path. Wire parameter IDs through AUv3 parameter tree. Write automation capture during plugin UI edits.

### 8. Multi-core render scheduling
**Today:** single-threaded render block. `activeChannelIndices` is built but processed sequentially.
**Pro DAWs:** dependency graph of tracks/buses, scheduled across all cores; pipelined processing of non-dependent tracks in parallel.
**Fix:** Per-track render tasks submitted to a fixed GCD queue; dependency edges for bus routing. Audio thread waits on the graph via a single dispatch group. Substantial — ~800 lines + threading review.

### 9. High-order plugin latency compensation
**Today:** PDC works per-channel with a flat 1 s maximum.
**Pro DAWs:** report each plugin's latency, compute the global max, insert compensating delay on every non-zero-latency path so all outputs are sample-aligned at the master. Bus + send paths have their own groups.
**Fix:** Query `AUAudioUnit.latency` at plugin load, propagate max through the render graph (builds on #8). Current per-channel path is a subset of the full solution.

### 10. Project auto-save & crash recovery ✅ **SHIPPED**
`Timeline.onAutosaveTick` fires every 60 s off the 30 Hz UI sync loop. `AudioHost.autosave(state:)` writes via `MADWriter` to `~/Library/Application Support/ToooT/autosave/{safeTitle}_{ISO8601}.mad` on a utility-QoS background Task. Rolling 10-file per-title window. `AudioHost.latestAutosave(for:)` available for launch-time crash-recovery UI (prompt not yet wired — trivial follow-up).

## MIDI gaps

### 11. Piano Roll with CC lanes
**Today:** `PianoRollView` exists (~150 lines) — note painting + erase. No expression lanes.
**Pro DAWs:** draggable velocity, aftertouch, pitch bend, mod wheel, any CC, per-note parameters (MPE).
**Fix:** Expand `PianoRollView` with CC lane editor. Bind to `Instrument.automationLanes[cc]`.

### 12. MPE (MIDI Polyphonic Expression)
**Today:** single-channel MIDI 1.0 + basic UMP.
**Pro DAWs:** per-note pitch bend, per-note pressure, per-note Y-axis (slide). Native support across Logic, Bitwig, Ableton Live; ships in every modern MPE controller (Roli, LinnStrument).
**Fix:** Extend `TrackerEvent` with per-note voice ID, pitch bend, pressure, Y. Route MPE events through MIDI 2.0 UMP (ToooT already uses UMP; just need the "configuration" message handling).

### 13. Arpeggiator as a MIDI effect
**Today:** `arp` JIT macro generates notes into the pattern.
**Pro DAWs:** live arpeggiator as a MIDI plugin between input and instrument — mode, rate, octaves, pattern, hold, sync to host.
**Fix:** `ToooT_Plugins/ArpeggiatorMIDI.swift`. Insert in the MIDI path on a channel.

### 14. Scale & chord modes
**Today:** raw note entry.
**Pro DAWs:** constrain input to scale; chord-generator shortcut (one key → triad); transpose / invert / voice-lead helpers.
**Fix:** `PlaybackState.activeScale`; piano roll + tracker entry filter notes through it.

### 15. ARA2 (Audio Random Access)
**Today:** none.
**Pro DAWs:** Melodyne + RipX live editing of audio regions as if they were MIDI — visible pitch contours, draggable notes, regenerate formants.
**Fix:** Vendor the ARA2 SDK (MIT-compatible terms from Celemony). Surface via a new `ARAHost` layer. Route audio clips through the ARA plugin for analysis and playback.

## Session / performance gaps

### 16. Session / clip-launch view (Ableton paradigm)
**Today:** pattern-linear playback.
**Pro DAWs:** grid of clip slots; trigger clips by cell; scenes = horizontal rows; quantized launch (wait for bar/beat); follow actions.
**Fix:** `SessionGrid` model + view. Backed by `[PatternClip | AudioClip]` per cell. Launches drive `PlaybackState.pendingLaunchCell`; `processTickSequencer` consumes on bar/beat boundaries.

### 17. Scene automation
**Today:** none.
**Pro DAWs:** scenes as named snapshots of mixer/automation state; scene recall switches state at a quantized boundary.
**Fix:** `Scene` = `{channelVolumes, pans, mutes, soloes, sends, pluginStates}` snapshot. Stored in project. Recall via snapshot-swap-style atomic replacement.

## Mastering / quality

### 18. Multiband compressor / linear-phase EQ / true-peak limiter ⚠ **PARTIAL**
Safety limiter + ✅ `TruePeakLimiter` AUv3 (4× inter-sample peak detection, 64-sample look-ahead, ceiling in dBTP, instant attack / exponential release). Still pending: multiband compressor, linear-phase EQ (Hilbert FIR or FFT convolution).

### 19. Dithering on export ✅ **SHIPPED**
`MasteringExport.applyDither(bufferL:bufferR:frames:bits:mode:)` in `ToooT_Plugins`. Rectangular and TPDF modes. Per-bit scaled amplitude (±½ LSB). Integrated into `AudioHost.exportAudio(to:state:options:)` via `ExportOptions`.

### 20. Loudness normalization on export ✅ **SHIPPED**
`MasteringExport.normalizeLoudness(...)` runs a two-pass measure-then-apply against the full mix buffer. Targets: `.spotify` (−14), `.appleMusic` (−16), `.youtube` (−14), `.ebuR128` (−23), `.amazonMusic` (−14). Gain is capped by the target's true-peak ceiling. tanh soft-clip on any residual overs. Returns a `LoudnessReport`. UAT verifies post-normalize LUFS hits target within ±3 dB and ceiling is respected.

## Audio I/O & format

### 21. Non-44.1 multi-channel I/O (5.1 / 7.1 / Atmos)
**Today:** stereo master bus only.
**Pro DAWs:** surround / immersive formats; Dolby Atmos with object-based rendering; ambisonic authoring.
**Fix:** Builds on PHASE groundwork + multi-output AVAudioEngine bus. Surround panners per channel. Atmos requires a licensed renderer (Dolby) — out of scope for v1.

### 22. AAF / OMF import / export
**Today:** `.mad` native only.
**Pro DAWs:** AAF is the post-production interchange format; OMF is legacy but still common. Required to hand sessions to a film mix.
**Fix:** Third-party AAFLib exists (LGPL — requires dynamic linking for MIT compatibility). ~1500 lines shim.

### 23. Video sync — finish the implementation
**Today:** `.mp4`/`.mov` load referenced in README but no visible wiring.
**Pro DAWs:** timecode-locked video preview; LTC / MTC chase; frame-accurate edit.
**Fix:** `AVPlayer` + `CADisplayLink` sync. `EngineSharedState.playheadPosition` already exists; drive video playhead from it. `AVPlayerItem.timebase` for LTC output.

## UI / UX polish

### 24. Command palette (Cmd+K) ✅ **SHIPPED**
`ToooT_UI/CommandPalette.swift`. `CommandRegistry` singleton with weighted fuzzy match (exact-prefix > word-prefix > substring > category). `CommandPaletteView` SwiftUI sheet with keyboard navigation. `registerDefaults(state:host:timeline:)` seeds Transport/Mastering/File/Edit/Track/View commands. UAT verifies ranking + multi-token AND + category-only matching + case insensitivity + id replacement.

### 25. Keyboard shortcut customization
**Today:** hardcoded in SwiftUI views.
**Pro DAWs:** user-editable keymaps, presets per DAW family ("Pro Tools mode", "Logic mode").
**Fix:** `KeyBindings` model + preferences UI + runtime dispatch.

### 26. Undo history browser
**Today:** Cmd+Z stack.
**Pro DAWs:** Logic / Photoshop / VSCode style — visual list of past states, jump to any point.
**Fix:** Expose `undoStack` in a side panel with labels per operation. Requires labeling each `snapshotForUndo()` call site.

### 27. Template projects ✅ **SHIPPED**
`ToooT_UI/Templates.swift`. Programmatic builders (not binary blobs) for 4 starters: `blank`, `drum-starter` (Euclidean 7/16 hi-hat + 4×4 kick + snare on 2/4 at 128 BPM), `ambient-pad` (C/F drone at 78 BPM), `techno-basic` (kick + off-beat open hat + bassline at 125 BPM). `TemplateManager.materializeBuiltInsIfMissing()` writes them to `~/Library/Application Support/ToooT/templates/` on first launch. User-saved templates dropped in the same dir get enumerated alongside built-ins.

### 28. Localization
**Today:** English strings hardcoded.
**Pro DAWs:** 10+ languages. Reaper alone has 30.
**Fix:** String Catalog (Xcode 15+) + `String(localized:)` everywhere. Long tail but mechanical.

### 29. Accessibility (VoiceOver, dynamic type)
**Today:** untested.
**Fix:** `accessibilityLabel` + `accessibilityValue` on every interactive control. `@ScaledMetric` for font sizes. Keyboard-only navigation through all views.

### 30. macOS integration polish
**Today:** Basic app structure.
**Pro DAWs / native Mac apps:** Finder Quick Look for `.mad`, Spotlight indexing, Shortcuts.app actions, drag-and-drop from Finder, system media keys, "Services" menu.
**Fix:** `mdimporter` for Spotlight, `QLPreviewExtension`, `AppIntents` for Shortcuts.

## Ecosystem / community

### 31. Preset sharing / cloud presets
**Today:** plugin state in `.mad` TOOO chunk.
**Pro DAWs:** user uploads presets to a community library; DAW browses and loads them.
**Fix:** Long-term. First step: `Instrument.exportAsPreset(url:)` + import. Cloud is v2.
### 32. Scripting API beyond JIT shell
**Today:** JIT shell operates on sequencer events.
**Pro DAWs:** Reaper has ReaScript (Python/Lua), Bitwig has Controller Scripts (JavaScript). Full DAW API accessible from scripts.
**Fix:** Embed Lua (via Swift bindings) or JavaScriptCore. Expose `PlaybackState`, `AudioHost`, `Instrument`, render helpers.

### 33. Collaboration (CRDT-based multi-user)
**Today:** single-user.
**Pro DAWs:** Splice, Soundtrap, Endlesss cloud. Ableton 13 announced real-time collab.
**Fix:** CRDT on `.mad` events + instrument bank. WebSocket sync server. Moonshot — months of work.

### 34. iPad / Vision Pro companion
**Today:** `Package.swift` declares `.iOS(.v18)` and `.visionOS(.v2)` platforms but no iOS/visionOS app target exists.
**Pro DAWs:** Logic Pro for iPad is the gold standard. Ableton Move is its own device. Vision Pro has Final Cut but no DAW.
**Fix:** Add `ProjectToooTApp-iOS` and `ProjectToooTApp-visionOS` targets. Share `ToooT_Core` / `ToooT_IO` / `ToooT_CLAP`. Re-do UI with Catalyst or native iOS.

## Testing / reliability

### 35. 24-hour 1024-channel stability test
**Today:** UAT is 111 assertions, ~2 second runtime.
**Pro DAWs:** internal QA runs projects for hours. ToooT needs the same.
**Fix:** Run a synthesized 1024-channel song for 24 hours; monitor memory / audio glitches / thread priority inversions. Part of Split 05 from `roadmap.md`.

### 36. XCTest port of UAT
**Today:** UAT is a single-file `main.swift` that print-asserts.
**Pro practice:** XCTest-based, runnable via `swift test`, test isolation, parallel execution, CI integration.
**Fix:** Move assertions into `Tests/ToooT_CoreTests/*Tests.swift`. Keep UAT runner for print-style observability.

### 37. Fuzzing for parser crash safety
**Today:** Parsers assume valid input.
**Pro DAWs:** Industry-standard `.mod`/`.it`/`.xm` parsers harden against malformed files. Pro Tools has bespoke fuzzers.
**Fix:** Add `libFuzzer` swift wrapper or ad-hoc fuzz harness. Feed random bytes at `MADParser.parse`, `FormatTranspiler.parseMetadata`, `MIDI2Manager.dispatchUMP`. Must not crash.

## Performance

### 38. GPU-accelerated DSP beyond normalize
**Today:** only `GPU_DSP.normalizeGPU` uses Metal.
**Pro DAWs:** FabFilter Pro-Q 4 does FFT on GPU. Some mastering limiters. GPU-accelerated convolution reverb.
**Fix:** Port `OfflineDSP.resample` / `timeStretch` / `smooth` to Metal compute shaders where they beat vDSP on M-series (generally only for N > ~10k with many parallel operations).

### 39. Cold-launch time budget
**Today:** untracked.
**Pro DAWs:** Logic launches in <5s; Live in ~3s; Reaper in <2s. Plugin scanning dominates.
**Fix:** Async plugin scan, deferred DSP compilation, lazy instrument bank allocation. Measure with `os_signpost`.

---

## Next-session priorities (recommendation)

Sorted by (user-visible impact) × (implementation cost):

1. **#1 Variable sample rate** — unblocks pro sessions at 48/96/192 kHz
2. **#6 LUFS + true-peak metering** — mastering credibility
3. **#5 Buses + sends** — foundational for pro mixing
4. **#10 Auto-save + crash recovery** — table stakes for anyone doing real work
5. **#24 Command palette** — huge UX win, small code
6. **#2 Linear arrangement view** — the single largest missing paradigm

#2 is a multi-session effort. The other five are each ~1–2 days and multiply ToooT's professional usability.
