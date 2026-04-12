# Spec: 04-neural-ane-acceleration

**Project:** ProjectToooT — macOS 2026 Native DAW  
**Module:** ToooT_Core (synthesis) + ToooT_UI (synthesis panel)  
**Track:** Parallel C (independent of UI coherence work)

## Goal

Accelerate the 6 working neural synthesis modules onto the Apple Neural Engine (ANE) and polish their UI integration. The modules already produce correct audio — this split is about performance acceleration and WWDC-quality presentation of the unique synthesis tiers.

## Background

See `requirements.md` §7 (Neural Engine & Algorithmic Synthesis) and `memory/project_status.md` §Working Features.

Interview finding: all 6 neural synthesis modules (BASSLINE, HARMONY, DRUMS, MARKOV MELODY, L-SYSTEM, SYNTH) are already functional. This is not ground-up implementation — it is ANE offloading, Markov cross-fade implementation, and synthesis tier UI.

The three synthesis tiers are brand identity — do not simplify or homogenize them:
- **Carbon Tier:** electromagnetic interference, shorted logic gates, data corruption textures
- **Biological Tier:** vocal fry, throat resonances, skeletal percussion, cardiac arrhythmia
- **Xenomorph Tier:** fractal noise, cellular automata, "Void Screech" and "Quantum Foam"

## What to Build

### Task A: ANE Profiling and Offloading
- Profile each of the 6 modules: identify which synthesis computation paths are ANE-suitable (matrix ops, convolution, inference)
- Convert suitable paths to CoreML models or use `MLCompute` for ANE dispatch
- **Critical constraint:** ANE inference must be fully async — results feed back into the synthesis pipeline without blocking or touching the audio render thread
- Measure latency introduced by ANE round-trip; ensure it does not exceed one audio buffer period

### Task B: Markov Layer Cross-Fades
- Implement Markov chain state transitions between synthesis tiers
- Cross-fades driven by real-time `algSeed` data (read atomically from `EngineSharedState`)
- Transition smoothness: `vDSP_vrampmul` for gain ramping during tier cross-fade (prevents clicks, per requirements §2)
- State machine must be RT-safe: all `algSeed` reads are atomic; no locking on the audio thread

### Task C: Synthesis Tier UI Panel
- Expose tier selection (Carbon / Biological / Xenomorph) in the synthesis panel within `TrackerWorkspace`
- Real-time parameter display: show current `algSeed` value and active Markov state
- Tier-specific parameter controls atoootpriate to each tier's character (e.g., "corruption intensity" for Carbon, "arrhythmia rate" for Biological)
- UI writes to synthesis parameters must go through `EngineSharedState` atomic bridge (not direct struct mutation)

## Constraints

- **ANE inference is async only** — never block the audio render thread waiting for ANE output
- **algSeed reads must be Atomic** — `EngineSharedState.algSeed` accessed with `Atomic<T>` (Synchronization framework)
- **Tier identity must be preserved** — do not normalize, soften, or simplify the Carbon/Biological/Xenomorph textures to make them "safer"
- **Output feeds UnifiedSampleBank pipeline** — synthesis output format must be compatible with the existing sample bank PCM path
- **Swift 6 strict concurrency** — synthesis UI panel follows same `@MainActor` rules as all other ToooT_UI code
- **Minimum macOS 16** — required for latest ANE access via CoreML and Synchronization framework

## Success Criteria

- [ ] At least 2 of 6 modules have ANE-accelerated paths with measurable latency reduction
- [ ] Markov cross-fades trigger correctly on `algSeed` change, no clicks or pops
- [ ] Tier selection UI functional: switch between Carbon / Biological / Xenomorph live
- [ ] ANE latency ≤ 1 audio buffer period (measured, not assumed)
- [ ] All existing UAT suites still pass (synthesis changes must not break tracker audio)
- [ ] No Swift 6 concurrency warnings in synthesis code paths

## Dependencies

**Needs from other splits:**  
- `UnifiedSampleBank` API (stable in current build — no dependency on other splits)  
- `TrackerWorkspace` scaffold for the synthesis UI panel (from 03-ui-coherence, but can stub during development)  

**Provides to other splits:**  
- ANE-accelerated synthesis modules ready for 05-platform-hardening to validate under 24-hour load
