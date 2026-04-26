# Changelog

All notable changes to ToooT are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Master linear-phase EQ in the master chain** — `LinearPhaseEQ`'s
  4096-point overlap-save FFT convolution is now instantiated by
  `AudioHost` and wired into `RenderBlockWrapper.masterEQBlock`. 10
  log-spaced bands (31 Hz – 16 kHz). `AudioHost.setMasterEQBand(_:dB:)`
  + `EngineSharedState.isMasterEQEnabled` for runtime control. Master
  chain order: EQ → stereo widen → reverb → safety limiter.
- **AUv3 plugin parameter automation** — `AudioHost.pluginParamRegistry`
  walks each loaded plugin's `parameterTree` and registers parameters
  under target IDs `plugin.<channel>.<slot>.<address>` (channel
  inserts), `plugin.<channel>.inst.<address>` (channel instruments),
  `plugin.bus.<bus>.<slot>.<address>` (bus inserts).
  `Timeline.syncEngineToUI` evaluates plugin-targeted automation lanes
  at UI tick rate and writes through `AUParameter.setValue`. Native
  engine params stay on the audio thread; plugin params live at UI
  rate where setValue is documented thread-safe.
- **Tempo automation** — new target ID `tempo.bpm` is honored by the
  audio thread's `applyTarget`. Lanes write directly to
  `state.pointee.bpm` at row boundaries, clamped to [20, 999].
- **Markers + time signatures** — `Marker` + `TimeSignatureChange` +
  `TimingMap` ship in `ToooT_Core`. `PlaybackState.timingMap` carries
  named cue points and a list of meter changes; `seekToMarker(named:)`
  jumps the playhead. Persisted in the `.mad` `TOOO` chunk via
  `exportAsPluginStateData`. Mid-song meter consumption by the render
  path is a follow-up.
- **Recording take lanes** — `RecordingTake` + `TakeLane` per channel,
  `RecordingMode { replace, overdub, loop }`. `commitTakeFromRecording`
  finalises the in-progress capture into the configured channel's
  stack honoring the mode. Replace clears prior takes; overdub / loop
  append latest-active. Codable for `.mad` persistence.
- **Arrangement engine consumption** — `SongSnapshot.arrangement`
  ships as an optional reference. When non-nil,
  `processTickSequencer`'s per-channel event lookup overrides the
  order-list path: a pattern clip on a track at `channelIndex N`
  routes the engine to play that pattern's events for channel N.
  Pattern-grid playback is the fallback when no clip is active. Honors
  track mute / solo. UAT 61 verifies. Pressing play on a populated
  ArrangementView now actually produces audible output. Audio (.audio)
  and MIDI (.midi) clip kinds are still pending.
- **Cold-launch profiling instrumentation** — `AudioHost.SetupTimings`
  exposes wall-clock per phase (engineBoot / internalDSPBoot /
  outputUnitBoot). UAT 57 measures and asserts < 250 ms steady-state.
  `AUv3HostManager` no longer auto-scans on init; Timeline kicks off
  `discoverPluginsAsync()` on a detached utility Task, removing the
  1–3 s `AVAudioUnitComponentManager` scan from cold launch's main
  thread.
- **AppIntents (Shortcuts.app)** — `OpenToooTProjectIntent` (file →
  open in app), `OpenLastAutosaveIntent`, `NewToooTProjectIntent`,
  plus `ToooTShortcutsProvider` so the intents surface in Spotlight
  and the Shortcuts gallery.
- **Crash-recovery prompt on launch** — `TrackerAppView` checks
  `AudioHost.recentAutosaves(maxAgeSeconds: 86_400)` on first appear;
  if anything is found, `CrashRecoveryPromptView` is shown as a sheet
  with restore-latest / dismiss actions. Engine work was already
  shipped in 2.0.0; this wires the UI half.
- **Render-path automation evaluator** — `AutomationSnapshot` is
  published atomically to `AudioRenderNode` and consumed at every row
  boundary. Supported target IDs: `ch.<N>.{volume,pan,send.<bus>}`,
  `bus.<B>.volume`, `master.volume`. Lock-free read/write mirrors the
  song-snapshot pattern. `Timeline.publishSnapshot` republishes
  whenever `PlaybackState` changes (UI Bezier lanes are converted to
  the Core lane format inline).
- **MAD metadata + thumbnail extractors** — `MADMetadataReader.read`
  returns title, format, pattern/channel/instrument counts, and
  instrument names from `.mad` and classic `.mod`/`.xm`/`.it`/`.s3m`
  files. `MADThumbnail.renderPNG` renders a tile-style preview of the
  first pattern via CoreGraphics + ImageIO. Pure Foundation — drops
  into a Quick Look `.appex` or Spotlight `.mdimporter` extension
  target unmodified. Recipes in `docs/MAD_QUICKLOOK_SPOTLIGHT.md`.
- **Cold-launch `os_signpost` instrumentation** — `AudioHost.setup`
  wraps an outer interval plus inner intervals on `EngineBoot`,
  `InternalDSPBoot`, `OutputUnitBoot`. `AUv3Host.scanLog` covers
  plugin discovery. Subsystem `com.apple.ProjectToooT` / category
  `ColdLaunch` for filtering in Instruments.app.
- **`exportAudio` switched to multi-core path** —
  `renderOfflineConcurrent` parallelizes voice processing across
  cores using a per-voice scratch pool. Bit-exact-modulo-fp-reorder
  parity with the serial path, verified by UAT 53.
- **UAT 53 rewritten** as a real serial-vs-concurrent parity test
  (16 simultaneous voices on saw samples; max diff < 1e-6). Replaces
  the previous silent-input no-op.
- **UAT 55** — automation snapshot lifecycle stress: 500 atomic swaps
  with a concurrent reader thread driving `renderOffline` calls;
  asserts every retired snapshot is released after
  `processDeallocations` drains.

### Fixed
- **Scratch-slot collision in `renderOfflineConcurrent`** —
  per-voice scratch slots were allocated as `idx % voiceThreadSlots`
  with `voiceThreadSlots = 8`. `concurrentPerform` doesn't pin
  iterations to threads, so any two voices with the same `idx % 8`
  could collide on the same `threadScratchL/R/Mono` buffers from
  different threads. Symptom: max abs diff of 0.054 between serial
  and concurrent render on a 16-voice test. Fix: `voiceThreadSlots =
  kMaxChannels` and `slot = idx` (no modulo). Memory cost ~20 MB
  allocated once at engine init. Material because v2.0.1's
  `exportAudio` switched to the concurrent path — anyone bouncing
  through it would have heard wrong output.
- **Undersized snapshot deallocation queues** — `automationDealloc`
  (capacity 64) and song `deallocationQueue` (capacity 128) silently
  dropped entries when `push` returned false, leaking the retained
  snapshot at each dropped pointer. Bumped both to 2048, comfortably
  absorbing realistic main-thread bursts.

### Changed
- **`renderResources.voiceThreadSlots`** is now `kMaxChannels` (was
  `8`) — sized for one slot per voice, no modulo aliasing.
- **UI Bezier automation types renamed** — `AutomationLane` /
  `AutomationPoint` in `ToooT_UI/Helpers.swift` are now
  `BezierAutomationLane` / `BezierAutomationPoint` to disambiguate
  from `ToooT_Core.AutomationLane` (render-path representation).
  `Timeline.publishSnapshot` continues to convert between them.
- **Homebrew cask** — `scripts/homebrew-tooot.rb` sha256 filled in
  for the v2.0.0 DMG.

### Documentation
- **`docs/FEATURE_ROADMAP.md`** — accuracy pass against actual code.
  Flipped 8 stale items to ✅ SHIPPED (#7 Automation, #10 Crash
  recovery, #11 Piano Roll CC, #12 MPE, #17 Scene automation, #23
  Video sync, #25 Keyboard shortcuts, #26 Undo browser); 4 to PARTIAL
  (#2, #8, #16, #30, #39). Refreshed pie chart counts and rewrote
  next-session priorities — the original top-five all shipped.
- **`docs/MAD_QUICKLOOK_SPOTLIGHT.md`** — recipes for wrapping
  `MADMetadataReader` and `MADThumbnail` in Quick Look `.appex` and
  Spotlight `.mdimporter` extension bundles via Xcode (SPM doesn't
  produce these bundle types directly).
- **`README.md`** — added AppIntents, multi-core export, render-path
  automation, MAD QL/Spotlight primitives, and macOS Native
  Integration sections; updated test count (100+ → 230+); removed
  broken CI badge; linked the new docs.

### Internal
- Cleaned all build warnings to zero: redundant `public` on
  KeyBindings extension static, unnecessary `nonisolated(unsafe)` on
  Sendable `OSLog` constants (AudioHost, AUv3Host), `var ok` →
  `let`, unused `songLength`, discardable result `_ =`,
  `CLAPHost.process` wrapped in nested `withUnsafeMutablePointer` to
  satisfy `[#TemporaryPointers]`.
- Cleanup: gitignore release artifacts (`dist/`, `*.dmg`, `*.dSYM`,
  `*.zip`); fix `var fadeClip` → `let fadeClip` warning in UATRunner.

## [2.0.0] — 2026-04-17

First major release. ~15 000 lines of new, tested code.

### Plugin hosting
- CLAP host (BSD-3, MIT-compatible) — real-time-safe, modern ABI.
  u-he / FabFilter / Arturia / Surge XT supported.
- VST3 host — direct Steinberg SDK integration (no JUCE dependency).
- AUv3 host — per-channel insert chains (4 inserts + 1 instrument
  per channel) and bus inserts on the 4 aux buses.

### Mastering
- ITU-R BS.1770-4 LUFS metering (momentary / short-term / gated
  integrated).
- True-peak detection + look-ahead limiter AUv3.
- LUFS-normalized export to Spotify (−14) / Apple Music (−16) /
  YouTube (−14) / EBU R128 (−23) / Amazon Music.
- TPDF dither on bit-depth reduction.
- Multiband compressor (3-band Linkwitz-Riley) + linear-phase FFT EQ
  (4096-point) bundled.

### Composition
- Arrangement timeline view (Pro Tools / Logic paradigm).
- Session grid view (Ableton Live paradigm) with quantized clip
  launch.
- Piano Roll with CC lanes (velocity / mod / expression / pan /
  pitch bend).
- MIDI 2.0 MPE — per-note pitch bend + pressure with voice tracking.
- Arpeggiator — 6 modes with hold, octaves, gate probability.
- Music theory — 16 scales, 14 chord qualities, frequency-domain
  quantization.
- Scenes — capture / recall full mixer state.
- Automation lanes with 5 curve types + read/write/touch/latch/trim
  modes.

### Workflow
- ⌘K Command Palette with fuzzy match over every shipped command.
- Keyboard shortcut customization — ToooT / Pro Tools / Logic Pro
  presets.
- Undo history browser — 50-level stack, jump-to-step.
- Project auto-save every 60 s with crash-recovery prompt on
  relaunch.
- JavaScript scripting via JavaScriptCore.
- Text-to-speech via AVSpeechSynthesizer + `/usr/bin/say`.
- Starter content — 32 in-code synthesized instruments.
- Template projects — Blank / Drum Starter / Ambient Pad /
  Techno Basic.
- MIDI panic (⌘.) — transport stop + all-notes-off.

### Engine + performance
- Variable sample rate — 44.1 / 48 / 88.2 / 96 / 192 kHz end-to-end.
- Multi-core offline render — `DispatchQueue.concurrentPerform` with
  per-thread scratch pool.
- Zero-allocation audio thread (Swift 6 strict concurrency).
- GPU DSP — 5-kernel Metal compute library.
- SOLA time-stretch + pitch-shift.
- Track freeze / stems / mastered export paths wired end-to-end.

### Quality
- UAT: 232 assertions / 0 failures.
- StressRunner: 11 integration scenarios / 0 failures.
- FuzzRunner for parser crash safety.

### Installation

```
brew tap mstits/tooot
brew install --cask tooot
```

Or download the DMG and drag to Applications. macOS 14+, Apple
Silicon.

[Unreleased]: https://github.com/mstits/Tooot/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/mstits/Tooot/releases/tag/v2.0.0
