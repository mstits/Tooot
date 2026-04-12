# Spec: 03-ui-coherence

**Project:** ProjectToooT — macOS 2026 Native DAW  
**Module:** ToooT_UI + ProjectToooTApp  
**Track:** Main (largest split — start immediately, runs alongside 01 and 02)

## Goal

Stabilize and integrate all ToooT_UI views into a coherent, fully functional DAW workspace. Every major view must open, render correctly, respond to user input, and stay wired to the engine. No crashes on view switch. WWDC target: full DAW feature parity in a single session.

## Background

See `requirements.md` §5 (User Experience & Interface), `memory/project_status.md` §Working Features and §Stubs.

Interview finding: "broken UI" is all views simultaneously — Metal grid, Piano Roll, Envelope Editor, Automation, Spatial Visualizer. This is an integration coherence problem, not isolated component bugs.

## What to Build

Work through these views in priority order (each must be stable before moving to the next):

### 1. TrackerWorkspace Layout
- Window management: persistent layout state across launches
- Navigation between views (pattern grid ↔ piano roll ↔ envelope ↔ automation ↔ spatial) without state loss
- Toolbar / transport controls always visible and functional

### 2. Metal Pattern Grid
- Verify 120Hz ProMotion via `MTKView` (not timer-based redraws — use display link)
- GPU-instanced cell rendering: thousands of cells, minimal CPU overhead
- Arrow navigation, note entry (Z–M keyboard layout), Cmd+C/V row copy-paste, Cmd+D duplicate — all must work
- Playhead animation must read **only** from `sharedState.playheadPosition` (L25) — never derive from `samplesProcessed`

### 3. Piano Roll
- Drag-to-paint note entry: erase mode on existing notes, paint mode on empty space
- Multi-touch trackpad support
- Visual velocity feedback per note
- Stable undo/redo integration (50 levels)

### 4. Envelope Editor
- Volume / pan / pitch envelope types
- Drag existing points, click background to add, right-click to delete
- Points must bind bidirectionally to engine envelope state

### 5. Automation Editor
- Draggable Bezier curves for all automatable parameters
- Implemented via SwiftUI `Canvas` + `DragGesture`
- Binds to `EngineSharedState` parameter slots

### 6. Spatial Visualizer
- 3D source positioning via drag
- **Bidirectional:** dragging in UI must update `SpatialManager` / PHASE in real-time
- `SpatialManager` position changes (e.g., from automation) must reflect in UI

### 7. Mixer
- Real-time level meters wired to render output (read from `EngineSharedState` snapshot)
- AUv3 insert rack visible: Stereo Wide + Pro Reverb slots

### 8. Video Sync
- `ScreenCaptureKit` feed displayed
- Sequencer playhead hard-synced to video playback position (`AVFoundation` timecode)

## UI/UX Philosophy (Apple Silicon Performance)

- **Metal-first rendering:** Pattern grid and any timeline component must use Metal (`MTKView`) — no CoreGraphics fallback in hot paths
- **ProMotion-adaptive:** Tie render loop to `CADisplayLink` / `MTKView` preferred frame rate (120Hz on ProMotion displays, graceful fallback)
- **One atomic bridge:** `EngineSharedState` is the only legal read path from UI to engine — take a snapshot per frame, never dereference live audio-thread pointers from `@MainActor` code
- **SwiftUI for controls, Metal for grids:** SwiftUI `Canvas` + gestures for Automation Bezier; Metal instanced rendering for the tracker grid and piano roll keys
- **Playhead as truth:** All animations derive from `sharedState.playheadPosition` (L25) — a `Float` written by the render block as `Float(row) + Float(tick)/Float(ticksPerRow)`

## Critical Rules (Must Not Violate)

| Rule | Source |
|---|---|
| Never write UI-owned BPM/tempo to engine during playback | L21 |
| Playhead position = `sharedState.playheadPosition` only | L25 |
| Tremolo/vibrato: transient display values only, never stored in view model | L24 |
| All `@MainActor` UI must use `EngineSharedState` snapshot — no direct audio struct access | Swift 6 |
| StereoWide reads both channels from a scratch copy before computing newL/newR | L23 |

## Constraints

- **Swift 6 strict concurrency** — all UI code must be `@MainActor`; no `@unchecked Sendable`
- **No timer-based redraws** — use display link or `onChange` driven by `EngineSharedState` published snapshot
- **Undo/Redo must survive view switches** — 50-level stack must not be scoped to a single view

## Success Criteria

- [ ] All 8 views open without crashing
- [ ] Metal grid renders at 120Hz; playhead animates smoothly during playback
- [ ] Piano Roll: paint/erase notes, undo/redo works
- [ ] Envelope Editor: add/move/delete points, changes persist
- [ ] Automation: Bezier curves draggable, bound to engine params
- [ ] Spatial Visualizer: drag source → PHASE position updates in real-time
- [ ] Mixer: meters move during playback; AUv3 rack visible
- [ ] Video Sync: playhead tracks video timecode
- [ ] No Swift 6 concurrency warnings in ToooT_UI module

## Dependencies

**Needs from other splits:**  
- `EngineSharedState` snapshot API (stable after 01-audio-engine-perf, but can work against current version)  
- Lossless save/load (02-io-save-load) for "Save Project" menu item  

**Provides to other splits:**  
- Stable `TrackerWorkspace` scaffold that 04-neural-ane-acceleration's synthesis UI slots into
