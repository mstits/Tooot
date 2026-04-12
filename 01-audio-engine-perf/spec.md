# Spec: 01-audio-engine-perf

**Project:** ProjectToooT — macOS 2026 Native DAW  
**Module:** ToooT_Core  
**Track:** Parallel A (independent of UI and I/O work)

## Goal

Eliminate the two biggest CPU bottlenecks in the audio render path, targeting Apple Silicon M-series efficiency. Core audio is already production quality (17 UAT suites passing) — this is pure performance work.

## Background

See `requirements.md` §2 (Core Audio Engine) and `memory/project_status.md` §Known Performance Gaps.

The engine is correct but has two known scalar hotspots:

1. **SynthVoice resampler** — 4-point Hermite interpolation implemented as a per-sample scalar loop. Target: `vDSP_vlint` vectorized path.
2. **AudioRenderNode channel iteration** — iterates all available channels (up to 1024 per requirements, 256 per current build) every render cycle even when most are empty. Target: active-channel bitmask.

## What to Build

### Task A: Vectorize SynthVoice Resampler
- Replace the per-sample Hermite loop in `SynthVoice.process()` with `vDSP_vlint`
- **Critical OOB guard (L32):** `vDSP_vlint` reads `floor(i)` and `floor(i)+1`. For resample factor F, source count N: `maxNewCount = (N-1) / F`. Cap `newCount = min(maxNewCount, N/F)`. Off-by-one causes silent memory corruption.
- Maintain loop wrapping for ping-pong and reverse looping modes (L27: loop bounds check must gate behind `!isLooping`; Hermite lookahead indices must wrap around loop region, not clamp to `sampleLength-1`)
- Validate interpolation quality: octave-down should produce 439–440 zero-crossings (test 16 baseline)

### Task B: Active-Channel Bitmask in AudioRenderNode
- Add a bitmask (e.g., `UInt64` array or `[Bool]`) tracking which channels have active voices
- Update the bitmask atomically when voices are triggered or complete (RT-safe, no locking)
- Skip empty channels in the render loop without iterating their DSP path
- The shared render logic lives in `processTickSequencer(wrapOnEnd:)` (L33) — do not duplicate any logic; changes here apply to both `renderBlock` and `renderOffline`

## Constraints

- **No heap allocation on the render thread** — bitmask must be pre-allocated; `vDSP_vlint` buffers must be pre-allocated from the UMA slab or stack
- **Swift 6 strict concurrency** — bitmask writes must be `Atomic<T>` or happen only on the audio thread
- **masterVol = 0.5** (L26) — do not change the gain constant
- **Oscillating effects must not write back to base properties** (L24) — do not touch tremolo/vibrato paths
- **UAT must stay green** — all 17 suites must pass after changes; waveform correlation ≥ 0.99 (test 15)

## Success Criteria

- [ ] `vDSP_vlint` resampler implemented with correct OOB guard
- [ ] Active-channel bitmask skips empty channels in render loop
- [ ] All 17 UAT suites pass
- [ ] Perf microbenchmark: cycles-per-frame reduced measurably (establish baseline before starting)
- [ ] No new Swift 6 concurrency warnings

## Dependencies

**Needs from other splits:** None — fully self-contained in ToooT_Core.  
**Provides to other splits:** Stable `EngineSharedState` snapshot API (used by 03-ui-coherence for playhead animation).
