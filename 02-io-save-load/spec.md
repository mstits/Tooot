# Spec: 02-io-save-load

**Project:** ProjectToooT — macOS 2026 Native DAW  
**Module:** ToooT_IO  
**Track:** Parallel B (independent of audio perf and UI work)

## Goal

Make project save/load lossless and production-ready. A DAW that cannot save its own projects cannot be demoed at WWDC. This is a critical early deliverable.

## Background

See `requirements.md` §3 (I/O & Standards) and `memory/project_status.md` §Stubs / Incomplete.

The parsing side (MADParser, FormatTranspiler) is largely working — MOD/XM/IT all load, finetune is read correctly (L29). The write side has known gaps:

- `MADWriter` saves hardcoded "ToooT Project" as title regardless of loaded song
- `MADWriter` does not serialize finetune back to header byte 24 lower nibble
- MIDI import has a basic parser but needs better track/channel mapping

## What to Build

### Task A: MADWriter Lossless Round-Trip
- Serialize actual song title from the loaded `MADMusic` / `UnifiedSampleBank` metadata
- Write finetune back to instrument header byte 24, lower nibble (values -8 to +7, two's complement nibble)
  - This is the inverse of the L29 parse: `pow(2, finetune/96.0)` — the nibble value must survive round-trip
- Verify all `UnifiedSampleBank` PCM data is serialized (requirements §3: "zero-loss project saving")
- Add regression test: load a reference MOD file, save it, reload it, assert:
  - Song title matches
  - Finetune nibble byte-for-byte identical
  - Audio output waveform correlation ≥ 0.99 against original

### Task B: MADParser Dynamic Sample Offsets
- Requirements §3: `MADParser` must support dynamic sample offsets and lengths for third-party MOD/MAD files
- Audit current parser for hardcoded offset assumptions; fix any that fail on non-canonical files

### Task C: MIDI Import Track/Channel Mapping
- Current state: basic MIDI parser exists, stub-level track/channel mapping
- Improve: map MIDI tracks to channels intelligently (by program, by track name, by channel number)
- Minimum: load a standard General MIDI file and have each track land in the correct tracker channel

## Constraints

- **Do not break existing UAT** — MOD/XM/IT load tests (suites 1–14+) must all remain green
- **Finetune formula is fixed** (L29): `pow(2, finetune/96.0)` — do not alter the math
- **MADParser must support dynamic offsets** per requirements §3 — no hardcoded byte positions
- **MIDI 2.0 is out of scope here** — that belongs to 05-platform-hardening; this split targets standard MIDI import

## Success Criteria

- [ ] MADWriter serializes actual song title
- [ ] MADWriter writes finetune nibble; byte-for-byte verified round-trip test passes
- [ ] All existing UAT suites remain green
- [ ] At least one real-world third-party MOD file loads correctly with dynamic offsets
- [ ] A standard MIDI file imports with recognizable track/channel assignment

## Dependencies

**Needs from other splits:** None — fully self-contained in ToooT_IO.  
**Provides to other splits:** Lossless save/load foundation that 03-ui-coherence's "Save Project" UI depends on.
