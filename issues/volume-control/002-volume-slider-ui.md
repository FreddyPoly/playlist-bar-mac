---
id: volume-control-002
title: Volume slider in the dropdown
status: done
security: false
owner: agent
depends_on: [volume-control-001]
spec_ref: "SPEC.md#ui-menu-bar-dropdown"
---

## Description

Expose `volume-control-001`'s volume level as a slider control in the menu bar dropdown, per
SPEC.md's "UI (menu bar dropdown)" section.

## Acceptance criteria

- A slider in the dropdown (alongside the transport controls) reflects and changes the current
  volume level in real time while dragging, not only on release.
- Dragging it while a track is playing changes the audible volume immediately.
- Reflects the persisted level on dropdown open (including right after a relaunch, before any
  interaction).
- Visually consistent with the rest of the dropdown's existing controls (`ContentView.swift`) —
  match the project's established SwiftUI conventions there rather than introducing a new style.

## Notes

Added 2026-08-09 alongside `volume-control-001`. No numeric readout required by the spec (matches
the existing "no duration display" minimalism already established for the track list) — a plain
slider is sufficient unless a future decision says otherwise.

**Implemented 2026-08-09**: a `Slider(value:in:)` between the transport controls and the track
list, bound to `controller.masterVolume` via a get/set `Binding` (same pattern as
`playlistSelection`) whose setter calls `controller.setMasterVolume(_:)` — `Slider`'s own drag
gesture updates the binding continuously, giving the real-time behavior the acceptance criteria
require without any extra debounce/throttle logic. Flanked by two speaker SF Symbols
(`speaker.fill`/`speaker.wave.3.fill`), no numeric readout, matching the app's established
minimalism. Live interactive verification (does it *feel* right when actually dragged) is
deferred to this feature's `qc` pass, per this project's established workflow — reviewed manually
in place of `/code-review` (no git repo yet); no issues found.
