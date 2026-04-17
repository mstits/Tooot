# ToooTShell JIT Reference

A floating console for code-driven composition. Commands operate on the current `PlaybackState.sequencerData` and update the live engine via `swapSnapshot` — so changes take effect on the next audio buffer.

Open with the "shell" button in the toolbar (or the default binding).

## Command syntax

`command arg1 arg2 …` — space-separated. Channel / row / instrument arguments are 1-indexed where noted.

Multi-command lines are supported with `;`:

```
fill 1 C-4; fade 1 out; bpm 140
```

## Core commands

| Command | Effect |
|---|---|
| `bpm N` | Set global BPM. Takes effect immediately. |
| `tpr N` | Set ticks-per-row (playback speed). |
| `fill CH NOTE` | Fill channel `CH` with `NOTE` on every row of the current pattern. |
| `clear CH` | Clear channel `CH`. |
| `copy SRC DST` | Duplicate all events from channel `SRC` to channel `DST`. |
| `reverse CH` | Reverse note order on channel `CH`. |
| `shuffle CH` | Randomize row order on channel `CH`. |
| `fade CH in|out` | Apply a linear velocity ramp down the pattern. |
| `humanize CH AMT` | Randomize velocity and timing by `AMT` (0.0–1.0). |
| `evolve CH` | Mutate existing notes probabilistically. |

## Generative

| Command | Effect |
|---|---|
| `euclid CH N K` | Write a Euclidean rhythm of `K` hits over `N` steps on channel `CH`. |
| `tidal CH PATTERN` | TidalCycles-style pattern string (e.g. `"c4 [e4 g4] c4"`). |
| `arp CH ROOT PATTERN` | Generate an arpeggio from `ROOT` following `PATTERN` (e.g. `up`, `down`, `updown`). |

## Macros

Define reusable command blocks:

```
macro build = copy 1 2; fade 2 out; humanize 2 0.1
```

Run with:

```
build
```

Macros persist for the session. Future work: `macro save NAME` to persist to disk.

## Keyboard

- `↑` / `↓` — navigate command history
- `Tab` — complete command name
- `Enter` — execute
- `⌘K` — clear console

## Implementation

Lives in `Sources/ToooT_UI/JITConsoleView.swift`. Commands parse to an internal AST and execute against `PlaybackState` on the main actor. All mutations trigger `Timeline.sequencerSnapshot` → `renderNode.swapSnapshot` so the engine sees new events on the next buffer with no audio-thread churn.

Covered by UAT suite 25 (Advanced ToooTShell JIT Macros).
