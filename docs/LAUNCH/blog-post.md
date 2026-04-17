# Building a Zero-Allocation Audio Engine in Swift 6

## Why I wrote another DAW

Every macOS DAW I looked at had at least one of these problems: proprietary (Logic/Pro Tools), expensive (Live $450, Bitwig $400), closed ecosystem (iOS-only), or tied to a cross-platform toolkit like JUCE with a GPL/commercial dual license incompatible with what I wanted.

So I wrote ToooT. Swift 6, Apple Silicon-native, MIT, ~15k lines of code. What's below is the interesting technical parts.

## The audio thread should allocate zero times

The audio callback on macOS is called every 256-4096 frames (6-100 ms) at the system's real-time priority. The moment it blocks — on a malloc, a mutex, an ARC retain — you get an underrun, which the user hears as a pop or glitch.

Most DAWs solve this with C/C++ and manual memory management. ToooT is Swift, which means every line is an opportunity to accidentally allocate.

**The solution**: pre-allocate everything at engine setup, pass `UnsafeMutablePointer<Float>` everywhere in the render path, use `@inline(__always)` on hot functions, and run with Swift 6's strict concurrency model so the compiler tells you when you've strayed into actor-isolated territory.

```swift
public final class RenderResources: @unchecked Sendable {
    public let voices:          UnsafeMutablePointer<SynthVoice>
    public let scratchL:        UnsafeMutablePointer<Float>
    public let scratchR:        UnsafeMutablePointer<Float>
    public let sumL:            UnsafeMutablePointer<Float>
    public let sumR:            UnsafeMutablePointer<Float>
    public let busL:            UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    public let busR:            UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    public let threadScratchL:  UnsafeMutablePointer<UnsafeMutablePointer<Float>>  // 8 slots
    // …
}
```

## The UI-audio bridge is one atomic pointer

When the user adds a note in the pattern grid, the UI needs to get that change to the audio thread without locking it. Classic solution: a producer-consumer ring buffer. ToooT uses something simpler — **atomic pointer swap**:

```swift
public func swapSnapshot(_ new: SongSnapshot) {
    let newBox  = SnapshotBox(new)
    let newRaw  = UInt(bitPattern: Unmanaged.passRetained(newBox).toOpaque())
    let oldRaw  = _snapshotPtr.exchange(newRaw, ordering: .acquiringAndReleasing)
    if oldRaw != 0 { _ = deallocationQueue.push(oldRaw) }
}
```

The audio thread does a single atomic load:

```swift
let raw = node._snapshotPtr.load(ordering: .acquiring)
let snapshot = Unmanaged<SnapshotBox>.fromOpaque(UnsafeRawPointer(bitPattern: raw)!).takeUnretainedValue().snapshot
```

Old snapshots are deallocated on the main thread by draining `deallocationQueue` — so the audio thread never waits for ARC and never hits the allocator.

## Plugin hosting without JUCE

JUCE is the industry-standard cross-platform audio framework. It's dual-licensed GPL / commercial. For an MIT-licensed project, either license is problematic — the GPL version requires relicensing the entire consumer, and the commercial version costs $40-$800/year.

ToooT supports three plugin formats without JUCE:

**AUv3** via Apple's system `AVAudioUnitComponentManager`. Covers virtually every major macOS plugin.

**CLAP** via a 200-line vendored header (CLAP is BSD-3-Clause). dlopen the `.clap` bundle, resolve the `clap_entry` symbol, call `get_factory()`. Modern real-time-safe ABI, growing adoption: u-he Diva, FabFilter Pro-Q, Arturia Pigments, Surge XT all ship CLAP.

**VST3** directly against Steinberg's SDK (not via JUCE). Steinberg offers a free developer license to anyone who registers. That's what Bitwig and Renoise use. Gated behind `TOOOT_VST3_SDK_AVAILABLE` so ToooT ships clean without vendoring the SDK.

## ITU-R BS.1770-4 LUFS metering

Standards-compliant LUFS is a filter chain + gated mean:

1. Pre-filter: high-shelf at 1681.974 Hz, +3.999 dB, Q=0.7071 (the "head effect")
2. RLB filter: high-pass at 38.135 Hz, Q=0.5003 (low-end rolloff)
3. Mean-square over the channel, summed across L+R
4. Gate: drop blocks below -70 LUFS absolute

At 48 kHz the biquad coefficients aren't constants — they have to be derived for the actual sample rate. In Swift, one biquad pair is about 50 lines including the RBJ derivation.

One subtle bug I hit: `reset()` must clear the filter's internal state (`x1`, `x2`, `y1`, `y2`). Otherwise the filter's transient decay after a loud passage keeps feeding K-weighted energy into the gated integrated mean for ~400 ms after the transport stops. I had `integratedLUFS` pinned at -37 dB after playback for half a day before I caught it.

## Multi-core offline render

The audio thread stays single-threaded for real-time safety. But offline rendering — when the user clicks "Export WAV" — has no deadline. `DispatchQueue.concurrentPerform` parallelizes voice processing across cores:

```swift
DispatchQueue.concurrentPerform(iterations: activeCount) { idx in
    let i = res.activeChannelIndices[idx]
    let slot = idx % RenderResources.voiceThreadSlots  // round-robin
    let sL = res.threadScratchL[slot]
    // … voice.process into scratch buffer …
    mixLock.lock()
    // vsma scratch buffer into master sum
    mixLock.unlock()
}
```

The per-thread scratch pool (8 slots × 5 buffers = 40 pre-allocated Float arrays) means concurrent voices don't fight over shared scratch. Typical projects with 20-200 voices see 4-6× speedup on M-series 8-core parts.

## What's next

The audio engine + plugin hosting + mastering chain + export are done. The visible surfaces — arrangement timeline, session-view clip launch — ship this week. The roadmap (`docs/FEATURE_ROADMAP.md`) lists 39 features; ~30 are now working code. The rest are either deferred with concrete fix plans, or documented as "skipping this because licensing" (Dolby Atmos, Celemony ARA2, AAF).

Source: https://github.com/mstits/Tooot

AMA about any of the DSP details.
