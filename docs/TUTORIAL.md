# ToooT Tutorial — From Blank Project to First Song in 20 Minutes

You don't need to know tracker conventions, you don't need to know SwiftUI, and you don't need to import any samples. We'll build a full loop from the empty state and export it to WAV.

## 1. Launch + pick a starting point

Open ToooT. On first launch the Dashboard tab shows four starter templates. Pick **Drum Starter** — it loads a 128 BPM project with a Euclidean 7/16 hi-hat, a four-on-the-floor kick, and a snare on beats 2 and 4. Press the space bar to hear it.

If you want to start from absolutely nothing, pick **Blank Project**. The rest of this tutorial assumes Drum Starter.

## 2. Load the Starter Kit sounds

The drum starter references instruments 1, 2, and 3. On a fresh install they're empty placeholders. Open **Command Palette** with `⌘K`, type `template`, pick `drum-starter` — done, the kit loads automatically.

If you want to browse the 32-instrument Starter Kit directly, open the JIT shell (toolbar → Shell icon) and type:

```
template drum-starter
```

The kit is synthesized programmatically: 8 drums, 4 basses, 4 leads, 4 pads, 6 percussion, 6 FX. Everything's in the UnifiedSampleBank.

## 3. Paint some notes

Switch to the **Piano Roll** tab. On the left you'll see a keyboard; to the right the pattern grid with 64 columns (one bar of 16ths × 4 beats).

Click and drag to paint notes. Right-click (or drag over an existing note) to erase. The velocity and expression strip is below the grid — use the segmented picker to switch between Velocity / Mod / Expression / Pan / Pitch Bend, then drag in the lane to edit per-column values.

For a starter melody: paint middle C every 4 columns across the pattern. It'll play in time with the drums.

## 4. Add bass

Switch to the **Sequencer** (tracker grid) tab. Select channel 4 (the next empty one). Open the JIT shell with `⌘K` → "Show Shell", or the toolbar button.

Type:

```
fill 4 48 4
```

`48` is MIDI note C3 (sub bass octave). `4` is the step — places a note every 4 rows. You now have a four-on-the-floor C3 pattern on channel 4.

Route it to the sub-bass sound:

```
ch 4 inst 9
```

Instrument 9 is Sub Bass in the Starter Kit. Press space. The bass should be audible under the kick.

## 5. Humanize

Straight sequences sound robotic. Humanize the hi-hat:

```
humanize 2 0.15
```

`0.15` = randomize velocity by ±15%. Listen again — it should breathe.

## 6. Add a pad

Switch to the Piano Roll, select channel 5 in the toolbar, paint a single long note (drag from column 0 to column 63) at E4. Open JIT:

```
ch 5 inst 17
```

Instrument 17 is Warm Pad. Press space. You should now hear drums + bass + pad.

## 7. Mix it

Open the **Mastering** (mixer) tab. You'll see one slot per channel. Turn the pad down to ~0.4 so it sits under the rest. If it's muddy, add some high-pass: open JIT:

```
pitch 17 2
```

Shifts the pad up by 2 semitones, pulling it out of the bass register.

## 8. Add a bus + reverb

Open JIT:

```
send 5 1 0.3
busvol 1 0.6
```

Sends 30% of channel 5's output into aux bus 1 at 60% bus volume. Bus 1 is where you'd load an AUv3 reverb plugin via the Pro Browser — drop Valhalla Supermassive (or any AUv3 reverb you own) on it. The pad now has a reverb tail.

## 9. Check levels

In any view, type `lufs` in the JIT shell:

```
LUFS-M: -17.3  LUFS-S: -18.2  LUFS-I: -19.1  TP: 0.412  Corr: +0.88
```

Integrated LUFS is currently too quiet for streaming. Target is Spotify's -14.

## 10. Export

```
export spotify
```

ToooT renders the whole project offline (concurrent across all CPU cores), runs it through the LUFS normalizer to exactly -14 LUFS with a -1 dBTP ceiling, applies TPDF dither to 16-bit, and writes `<SongTitle>.wav` to your Music folder.

That's it — a complete loop from blank to mastered WAV in 10 commands.

## Next steps

- **Save a scene** with `scene save 1 verse` so you can recall this mix later.
- **Write a script** — drop a `.js` file in `~/Library/Application Support/ToooT/scripts/` and run it via `script myfile.js`. The scripting API exposes `state.bpm`, `state.setNote()`, `state.fillChannel()`, `state.setSend()`, and more.
- **Arrangement view** — drop pattern clips on a linear timeline. The engine now actually reads from clips when an arrangement is loaded; pressing play sweeps through whatever you've laid out, falling back to the pattern grid for channels with no active clip.
- **Session view** — Ableton-style clip-launch grid for live performance + sketching.
- **Automation tab** — three-pane editor: pick a target from the sidebar (master volume, tempo BPM, per-channel volume / pan / send, per-bus volume, plugin params), click empty space to insert a point, drag to move, click a point to flip it Linear ↔ S-Curve. Tempo automation works mid-song.
- **Spatial tab** — top-down view: drag channel dots around the listener; angle pans, distance attenuates. Hover a dot for a live readout.
- **Generative tab** — pick a style (Techno / DnB / Ambient / Hip-Hop / Jazz / Breakbeat), key, scale; the 8 generators (Markov / Euclidean / L-System / Harmony / Bassline / Drum / Chord / Variation) honor those settings.
- **Set markers** — `marker add Drop 16` then `seek Drop` to jump the playhead to beat 16.
- **Record overdub takes** — set `recordingMode = .overdub` and `recordingChannel = N`; each pass stacks a new take on the channel's lane instead of replacing.
- **Speak with your DAW** — `say "start recording"` pipes through `AVSpeechSynthesizer`.
- **Trigger from Spotlight** — the AppIntents (Open Project / Open Last Autosave / New Project) appear in the Shortcuts gallery and Spotlight after the app has launched once.

For the full command reference, type `help` in the JIT shell.

For the roadmap + the DSP internals, see [ARCHITECTURE.md](ARCHITECTURE.md) and [FEATURE_ROADMAP.md](FEATURE_ROADMAP.md).
