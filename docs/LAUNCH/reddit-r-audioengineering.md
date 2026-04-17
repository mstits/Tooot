# r/audioengineering launch post

**Title:** [Free/Open-Source] ToooT — A new macOS DAW focused on audio-engine correctness and mastering-grade metering (LUFS, true-peak, phase correlation)

---

Hey r/audioengineering,

I've been writing a free, open-source DAW for macOS called **ToooT**. The short pitch: it combines the tracker/pattern workflow with a modern DAW (arrangement view, session view, piano roll) and ships mastering-grade metering + export out of the box.

**What's interesting for engineers:**

- **ITU-R BS.1770-4 LUFS** on the master bus — momentary / short-term / integrated (gated) — updated every audio buffer. No need for Youlean or Loudness Meter.
- **True-peak detection** with 4× linear-interp oversampling. Built-in true-peak limiter plug-in with ISP look-ahead.
- **LUFS-normalized export** to Spotify (-14), Apple Music (-16), EBU R128 (-23), YouTube (-14), Amazon (-14). Respects the -1 dBTP ceiling. Returns a report with measured LUFS + applied gain.
- **TPDF dither** on export when reducing from Float32 → 16/24-bit.
- **Phase correlation meter** (Pearson r over 400 ms).
- **Multiband compressor** (3-band Linkwitz-Riley crossover) + **linear-phase FFT EQ** (4096-point vDSP) bundled.
- **Variable sample rate**: 44.1 / 48 / 88.2 / 96 / 192 kHz, end-to-end.
- **Zero-allocation render thread**. All buffers pre-allocated. Lock-free snapshot swap between UI and audio.

**Plugin support:** AUv3 (native), CLAP (BSD-licensed, growing ecosystem: u-he / FabFilter / Arturia / Surge XT), VST3 (scaffolded against Steinberg's free developer license — no JUCE dependency).

**Pattern-based sequencing** plus **piano roll** plus **linear arrangement** plus **session-view clip launch**. You don't have to pick one paradigm — they share the same underlying clip model.

**Project export** includes per-channel stems + master bounce + mastered-export (with the LUFS normalize chain above).

MIT-licensed, MacOS-native (14+), Apple Silicon. Source at https://github.com/mstits/Tooot.

Happy to answer questions about the DSP internals — the K-weighting filter derivation was fun to get right.

---

*Edit: for the tracker-curious, the engine supports MOD/XM/IT loading + `.mad` native format with lossless round-trip including plugin state. You can drop any old tracker module in and it plays.*
