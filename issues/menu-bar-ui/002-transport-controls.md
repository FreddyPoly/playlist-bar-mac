---
id: menu-bar-ui-002
title: Transport controls
status: done
security: false
owner: agent
depends_on: [playback-controller-002, playback-controller-003]
spec_ref: "SPEC.md#ui-menu-bar-dropdown"
---

## Description

Add Previous / Play-Pause / Next / Reset buttons to the dropdown, wired to
playback-controller-002 (Previous/Next) and playback-controller-003 (Reset), with Play-Pause
reflecting/toggling current playback state from the AVPlayer wrapper (playback-engine-002).

## Acceptance criteria

- All four controls (Previous, Play-Pause, Next, Reset) are present and functional per their
  respective SPEC.md behavior rules.
- Play-Pause visually reflects whether audio is currently playing or paused, and toggles it.

## Notes

No duration/seek bar per SPEC.md — just play/pause state.

Added a `togglePlayPause()` method to `PlaybackController` (pause/resume the current item; no-ops
safely if nothing is loaded yet) and four `Button`s to `ContentView` wired to
`previous()`/`togglePlayPause()`/`next()`/`reset()`, using SF Symbols
(`backward.fill`/`play.fill`+`pause.fill`/`forward.fill`/`arrow.counterclockwise`). All four are
disabled (`.disabled(controller.currentIndex == nil)`) until a playlist is actually loaded, so
they can't be tapped into a meaningless state before anything is selected.

Verified `togglePlayPause()` directly: no-ops with nothing loaded (doesn't crash or flip
`isPlaying` to `true` with nothing to play), correctly pauses after a track starts, and correctly
resumes. The button wiring itself is thin (each just calls an already-verified controller method
in a `Task`), so risk is concentrated in `togglePlayPause()`, which is what was tested.

Same visual-verification limitation as menu-bar-ui-001: confirmed the app builds and launches
cleanly with this change, but couldn't screenshot the actual rendered buttons or click-test them
(this environment's `screencapture` doesn't show the real menu bar, and there's no Accessibility
permission for synthetic clicks). Please visually check the transport controls yourself.
