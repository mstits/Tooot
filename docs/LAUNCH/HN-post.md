# Hacker News — Show HN launch post

**Title:** Show HN: ToooT – An open-source macOS-native DAW with zero-allocation audio engine

**URL:** https://github.com/mstits/Tooot

**Text body:**

Hi HN —

I've been building ToooT, an open-source Digital Audio Workstation that combines the tracker/pattern paradigm (Renoise, OpenMPT) with modern DAW features (arrangement timeline, session-view clip launch, mastering metering). macOS-native, MIT-licensed, Swift 6.

Technical choices that might be interesting:

**Zero-allocation render thread.** The audio callback never hits `malloc`. All scratch buffers, voice pools, bus accumulators, and FFT workspaces are pre-allocated at setup. Lock-free snapshot bridge between UI and audio (single `Atomic<UInt>` pointer swap).

**Plugin hosting without JUCE.** JUCE's GPL/commercial dual-license is incompatible with MIT without a commercial grant. Instead:
- **AUv3** via Apple's system APIs (covers ~every major vendor's macOS builds)
- **CLAP** via a vendored 200-line BSD-3 header (u-he, FabFilter, Arturia, Surge XT all ship CLAP)
- **VST3** gated behind a free Steinberg developer license — no JUCE wrapper

**Mastering-grade metering.** ITU-R BS.1770-4 K-weighted LUFS (momentary/short-term/integrated), 4× true-peak detection, Pearson L/R phase correlation. Built-in export normalizes to Spotify (-14), Apple Music (-16), EBU R128 (-23) with TPDF dither.

**Real-time MPE.** MIDI 2.0 UMP dispatch handles per-note pitch bend + pressure with voice tracking so Roli / LinnStrument controllers route expressive data back to the correct active voice.

**Scripting and TTS.** JavaScriptCore-based scripting API exposes the DAW state. `say "pattern change coming up"` speaks through AVSpeechSynthesizer. macOS `say` CLI can render TTS directly into a sample slot.

**Open formats everywhere.** DAW Project (MIT) over AAF/OMF. Ambisonics (PHASE) over Dolby Atmos. Automerge-Swift for any future collaboration work. No proprietary SDKs in the dependency tree.

The tracker paradigm makes it weird for a certain kind of producer who's used to Ableton/Logic — but the arrangement view + session view + piano roll are all there if you want them. Think Renoise + Bitwig + the sanity of not having to pay $500 for the base tool.

Repo: https://github.com/mstits/Tooot — install via `brew tap mstits/tooot && brew install --cask tooot` when the tap goes live. Currently macOS 14+, Apple Silicon only.

Feedback, especially from audio-engineering folks, very welcome. AMA.

---

## Follow-up comment with demo details

> Any demo audio?

Running `StressRunner` on the repo validates the engine produces byte-identical output between serial and concurrent render paths, passes 1000-file parser fuzzing with no crashes, and holds memory stable (<10 MB growth over 1000 render cycles). The built-in `export spotify` target hits -14.000 LUFS within 0.001 dB of spec on a 1 kHz test tone. Audio demos coming with the 1.1 release.
