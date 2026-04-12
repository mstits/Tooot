# Spec: 05-platform-hardening

**Project:** ProjectToooT — macOS 2026 Native DAW  
**Module:** All modules + UATRunner  
**Track:** Final Phase (depends on 01, 02, 03, 04 all landing)

## Goal

Validate correctness at every level, audit Swift 6 concurrency across the full codebase, close remaining stubs, and achieve the WWDC demo-quality build. This is the gate before submission.

## Background

See `requirements.md` §6 (Stability & Testing) and §8 (macOS 2026 Platform Targets), and `memory/project_status.md` §Known Performance Gaps and §Stubs.

This split cannot start until the four parallel tracks are substantially complete — it is the integration validation layer.

## What to Build

### Task A: Swift 6 Concurrency Full Audit
- Enable `-strict-concurrency=complete` across all 5 modules if not already set
- Resolve any remaining `@unchecked Sendable` workarounds — replace with proper `Sendable` conformances or `Actor` isolation
- Verify: all cross-thread state changes go through `Atomic<T>` (Synchronization framework) — BPM, playhead, volume, algSeed
- Verify: `@MainActor` UI code never directly accesses audio-thread structs
- Target: **zero Swift 6 concurrency warnings** in a clean build

### Task B: Quantitative Regression Test Suite
The current "all tests pass" baseline only proves non-silence (L28 — this is insufficient). Expand to:

- **Waveform correlation test:** correlation ≥ 0.99 at step=1.0 (currently passes as test 15, but must be in CI)
- **Zero-crossing frequency tests:** verify specific output frequencies (220 Hz for octave-down, etc.)
- **Finetune round-trip test** (from 02-io-save-load): assert finetune nibble byte-for-byte after save → load cycle
- **Lossless offline render test:** offline render must be bit-accurate to real-time output
- **A/B comparison gate:** `assert(goodSec >= poorThreshold)` in the A/B result block (L30 — must fail CI on regression, not just print a warning)

All quantitative tests must run in CI (not just under Xcode.app).

### Task C: 24-Hour Stability Test
- 1024-channel continuous playback under high load
- Monitor: memory growth over time (must be zero — no leaks), thread priority inversions, audio glitches (buffer underruns)
- Target hardware: M4/M5 Ultra or equivalent; document the result
- Include the ANE synthesis modules running simultaneously (from 04)

### Task D: MIDI 2.0 UMP Migration
- Migrate from legacy MIDI to `MIDIInputPortCreateWithProtocol` (Universal MIDI Packets)
- Enable high-resolution velocity (14-bit) and per-note expression
- Maintain backward compatibility for MIDI 1.0 devices

### Task E: AUv3 Latency Compensation
- Measure reported latency of hosted AUv3 plugins (Stereo Wide, Pro Reverb, any user-loaded plugins)
- Implement automatic latency compensation in the render graph
- Verify alignment: AUv3 output must be time-aligned with non-processed channels

### Task F: Remaining Stubs
- **Import Classic App:** Implement dialog or display clean "not yet supported in this version" UI — no crash
- **QuickTime I/O:** Same — functional placeholder, not a crash
- **MADWriter title/finetune** (if not completed in 02): complete here as fallback

### Task G: WWDC Demo Preparation
- Define a reference project file: one showcase song that demonstrates all synthesis tiers, effects, and spatial positioning
- On first launch: load this reference project automatically (or prompt to load it)
- Release build audit: no debug overlays, console log spam, or placeholder labels visible
- Verify full feature parity in a single session: load project → play → edit Piano Roll → adjust Envelope → spatial drag → export WAV → no crashes

## Critical Lessons to Re-Verify

Before declaring this split done, explicitly re-test each of these regressions:

| Lesson | What to Verify |
|---|---|
| L21 | During playback, UI cannot write BPM to engine |
| L22 | ECx/EDx/EEx effects fire at correct tick, not tick 0 |
| L23 | StereoWide: scratch copy prevents L/R corruption |
| L24 | Tremolo/Vibrato: velocity and originalFrequency unchanged after playback |
| L25 | Playhead animation reads sharedState.playheadPosition |
| L26 | masterVol = 0.5 in renderBlock and renderOffline |
| L27 | Loop bounds check: gated behind !isLooping |
| L28 | Tests verify waveform correlation, not just non-silence |
| L29 | MOD finetune nibble parsed and applied in SynthVoice.trigger() |
| L30 | A/B assert() fails CI when goodSec < threshold |
| L31 | OfflineDSP.fade() multiplies — does not overwrite |
| L32 | vDSP_vlint index cap: maxNewCount = (N-1)/F |
| L33 | Single processTickSequencer() shared by renderBlock and renderOffline |
| L34 | IT bank-only load path goes through loadITSamples() |
| L35 | XM loopStart/loopLength/loopType populated in parseXMInstruments |

## Constraints

- **Minimum macOS 16** — PHASE, Synchronization framework, latest ANE access
- **Optimized for M4/M5 Ultra** — 24-hour test must target high-end Apple Silicon
- **No --no-verify, no @unchecked Sendable hacks** — clean build is the bar

## Success Criteria

- [ ] Zero Swift 6 concurrency warnings across all 5 modules
- [ ] All quantitative regression tests in CI (waveform correlation, zero-crossings, finetune round-trip)
- [ ] 24-hour stability test completes: zero memory growth, zero audio glitches
- [ ] MIDI 2.0 UMP input functional with a real MIDI 2.0 device or simulator
- [ ] AUv3 latency compensation implemented and verified
- [ ] All stubs show clean "not implemented" UI instead of crashing
- [ ] WWDC demo walkthrough completes without a crash on M4 hardware
- [ ] All 15 lessons (L21–L35) explicitly re-verified by test or code review

## Dependencies

**Needs from other splits:**  
- 01-audio-engine-perf: vectorized resampler + bitmask (needed for 24-hour stability test)  
- 02-io-save-load: lossless MADWriter (needed for demo project load)  
- 03-ui-coherence: all views functional (needed for WWDC demo walkthrough)  
- 04-neural-ane-acceleration: ANE modules (needed for full synthesis load in stability test)  

**Provides to other splits:** Nothing — this is the terminal split.
