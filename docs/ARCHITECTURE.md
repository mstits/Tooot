# ToooT Architecture

## Module graph

```
ProjectToooTApp (executable)
      │
      ▼
  ToooT_UI ─────────────────────► ToooT_IO
      │         │      │              │
      │         │      ▼              ▼
      │         │  ToooT_Plugins ► ToooT_Core
      │         │
      │         └───► ToooT_VST3 (Obj-C++)
      │
      └── host process: AudioHost, Timeline, TrackerWorkspace, Metal grid, JIT shell
```

| Module | Role |
|---|---|
| `ToooT_Core` | Zero-allocation render loop: `AudioRenderNode`, `SynthVoice`, `RenderResources`, atomic snapshot bridge, `EngineSharedState`, `AtomicRingBuffer`, `UnifiedSampleBank`. |
| `ToooT_IO` | Parsers / writers (`MADParser`, `MADWriter`, `FormatTranspiler`), `MIDI2Manager` (UMP in+out, clock), `SpatialManager` (PHASE). |
| `ToooT_Plugins` | Bundled DSP units: `ReverbPlugin`, `StereoWidePlugin`, `BaseEffect`. `AUv3HostManager` for system plugin discovery. Offline/pattern DSP helpers. |
| `ToooT_VST3` | Obj-C++ wrapper (`JUCEVST3Host`). Gated behind `TOOOT_VST3_SDK_AVAILABLE` — ships as an inert stub unless the Steinberg SDK is vendored. |
| `ToooT_UI` | SwiftUI workbench, Metal pattern grid, Piano Roll, envelope / automation / mixer / spatial views, JIT shell, `AudioHost` (the real engine wiring), `Timeline` (MainActor sync loop). |

## Thread model

Three threads are load-bearing:

| Thread | Actor / isolation | Rules |
|---|---|---|
| Audio I/O (CoreAudio) | `nonisolated` — entered via `renderBlock` | No heap allocation, no locking, no Swift ARC traffic, no `@MainActor` calls. Reads snapshot via a single `Atomic<UInt>` exchange. |
| UI | `@MainActor` | Never dereferences audio-thread pointers directly. Reads playback state via `EngineSharedState` snapshot fields written by the render thread (naturally atomic on arm64 aligned word stores). |
| Background | default actor | MIDI clock timer (`DispatchSource.userInteractive`), recording tap drain, async export. |

The single legal write path from UI to engine is `AudioRenderNode.swapSnapshot(_:SongSnapshot)`, which performs an atomic pointer exchange and queues the old snapshot for main-thread deallocation via `processDeallocations`.

## Render pipeline (per audio buffer)

```
AUInternalRenderBlock
  │
  ├─ 1. Load snapshot       (Atomic.load, retained for the block scope)
  ├─ 2. Drain event ringbuf (MIDI note-on/off from MIDI2Manager → voice.trigger)
  │
  ├─ 3. Per-tick loop while samplesProcessedInBlock < frames:
  │     a. processTickSequencer                 (shared by realtime + offline, per L33)
  │        – advance row, dispatch pattern effects, build activeChannelIndices
  │     b. for ch in activeChannelIndices:
  │        – voice.process                       (fast path: vDSP_vramp+vclip+vlint+vma;
  │                                              slow path: scalar Hermite for loop/pingpong)
  │        – sidechain peak track                (channelVolume gates ducking)
  │        – PDC delay buffer                    (per-channel circular)
  │        – spatialPush → SpatialManager        (channels 0–31, PHASE stream nodes)
  │        – vDSP_vsma into sumL/sumR            (with ducking multiplier)
  │     c. metronome tone sum
  │
  ├─ 4. masterVolume * 0.5                       (L26 — both renderBlock + renderOffline)
  ├─ 5. Master safety limiter                    (1ms attack / 100ms release)
  │                           — or soft clip (tanh) when limiter disabled
  ├─ 6. peakLevel for UI meters
  └─ 7. memcpy sumL/sumR → output bus
```

`RenderBlockWrapper` (in `AudioHost.swift`) wraps `renderBlock` with per-channel AUv3 insert chains (4 per channel + 1 instrument slot), then the global StereoWide + Reverb inserts.

## Snapshot lifecycle

`SongSnapshot` is a value type with raw pointers into `SequencerData`. `SnapshotBox` wraps it so Unmanaged retain/release can be used. `_snapshotPtr: Atomic<UInt>` holds the bitPattern of the current box.

Swap flow:
1. UI builds a new `SongSnapshot` (same-shape, possibly updated `events` / `instruments` pointers).
2. `swapSnapshot` calls `Unmanaged.passRetained(newBox).toOpaque()` → `_snapshotPtr.exchange`.
3. The old pointer tag is pushed into `deallocationQueue` (a lock-free ring buffer).
4. Main thread drains `deallocationQueue` via `processDeallocations()` and releases the retained box.

The audio thread reads the snapshot with `retain()` / `release()` around the block to keep it alive across a potential swap mid-render.

## Memory ownership

- `UnifiedSampleBank` owns one giant PCM slab (256 MiB default). Samples have no per-region retain count; `SampleRegion.offset+length` indexes the slab.
- `RenderResources` owns all render-thread scratch buffers (per-channel delay, voices, mixing sums, envelope scratch). Allocated once, lives for the life of `AudioEngine`.
- `EngineSharedState` is a plain C struct of `Int32` / `Float`. The only cross-thread state. All writes from UI must go through `Atomic<T>` wrappers in the `Synchronization` framework.

## MIDI routing

```
CoreMIDI device  ──► MIDIInputPortCreateWithProtocol(._2_0)
                      └─► MIDI2Manager.dispatchUMP  ──►  AtomicRingBuffer<TrackerEvent>
                                                             │
                                                             └─► AudioRenderNode drains
                                                                 on each render block

SynthVoice.trigger / noteOff  (internal) ──► AudioRenderNode.midiOut(n,v,c)
                                              └─► AudioHost wires this to
                                                  AudioEngine.midiManager
                                                  └─► MIDI2Manager.sendNoteOn (MIDI 1.0)
                                                      or sendUMPNoteOn (MIDI 2.0)
                                                      └─► CoreMIDI destination
```

The MIDI clock (`0xF8`, 24 ppqn) is driven by a `DispatchSource.userInteractive` timer in `MIDI2Manager.startClock(bpm:)`, not by the audio thread.

## PHASE spatial path

`AudioRenderNode.spatialPush` is invoked for channels 0–31 on every buffer with a mono sum of the channel's output. `AudioHost` routes this to `SpatialManager.pushAudio(channel:buffer:frames:)`, which copies into a pre-allocated `AVAudioPCMBuffer` pool and calls `PHASEPushStreamNode.scheduleBuffer`. PHASE applies the spatial mix and writes back to the system output — this is a parallel path, not in-line with the render bus.

Positions are updated from the UI via `SpatialManager.updateVoicePosition(channel:x:y:z:)`. The PHASE engine runs in `.automatic` update mode on its own scheduler.

## Plugin hosting

- **AUv3 inserts**: `AudioHost.loadPlugin(component:for:)` instantiates an `AUAudioUnit`, takes its `internalRenderBlock`, and stores it in `RenderBlockWrapper.pluginBlocks[ch*4 + slot]`. Up to 4 inserts per channel + 1 instrument. The per-channel loop in `coreAudioRenderCallback` walks these in order.
- **Bundled inserts**: `StereoWidePlugin`, `ReverbPlugin` are created as `AUAudioUnit` subclasses (`ToooTBaseEffect`) and kept alive on `AudioHost` (freeing them while their block is registered would crash the IO thread).
- **VST3**: `JUCEVST3Host` gates everything behind `TOOOT_VST3_SDK_AVAILABLE`. Without the SDK, `loadPluginAtPath:` fails, `sdkAvailable` returns `NO`, and `AudioHost.loadVST3Plugin` refuses to install the render block — guaranteeing a stub VST3 never silently replaces a working AUv3 instrument.

## File format

`.mad` is a chunked little-endian file:

| Offset | Size | Content |
|---|---|---|
| 0 | 4 | `MADK` / `MADG` / `Tooo` signature |
| 4 | 32 | Song title (ASCII, zero-padded) |
| 296 | 1 | `numPatterns` |
| 297 | 1 | `numChannels` |
| 299 | 1 | `numInstruments` |
| 302 | 999 | Order list (UInt8 per position) |
| 1301 | `numPat * 64 * numChn * 5` | Pattern cells (note, inst, vol, effect, param) |
| after patterns | `numInstruments * 232` | Instrument headers |
| after headers | variable | Int16 PCM sample data |
| after samples | optional | `TOOO` chunk: `[4b tag][4b LE len][JSON plugin states]` |

Instrument header (232 bytes): 32-byte name, sample length (LE 32-bit), loop start/length, finetune nibble at byte 24 (MOD-compatible) and byte 44 (MAD-extended, two's complement), stereo flag, loop type.

## Invariants (never violate)

See `memory/lessons_learned.md` for L21–L35. Short version: UI never writes BPM during playback; playhead reads `sharedState.playheadPosition` only; oscillating effects never mutate base properties; `masterVol = 0.5` in both render paths; `vDSP_vlint` OOB guard = `(N-1)/F`; shared `processTickSequencer` for realtime + offline; waveform correlation ≥ 0.99 is the test-pass bar (not mere non-silence).
