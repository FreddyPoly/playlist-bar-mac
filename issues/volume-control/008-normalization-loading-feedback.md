---
id: volume-control-008
title: Surface loudness-analysis wait in existing loading/buffering feedback
status: done
security: false
owner: agent
depends_on: [volume-control-007]
spec_ref: "SPEC.md#ui-menu-bar-dropdown"
---

## Description

Extend the dropdown's existing loading/buffering indicator (`menu-bar-ui-006`'s debounced
spinner, driven by `PlaybackController`'s combined waiting signal) to also cover
`volume-control-007`'s bounded wait on an out-of-order jump, so that wait doesn't look like a
frozen app.

## Acceptance criteria

- The wait introduced by `volume-control-007` is folded into the same combined waiting signal
  `ContentView` already derives (currently `isLoading || isResolvingTrack || isBuffering`) rather
  than adding a separate, differently-behaved indicator.
- Same debounce behavior already established (~300ms delay before showing, immediate hide when
  done) applies here too — a fast cache-hit (already-analyzed track) never flickers a spinner.
- If `volume-control-007`'s bounded timeout is reached and playback falls back to unnormalized,
  the loading indicator clears at that point (playback is no longer actually waiting) rather than
  persisting.

## Notes

Added 2026-08-09. Pure UI wiring on top of `volume-control-007`'s state — no new visual design,
reuses `menu-bar-ui-006`'s existing spinner treatment exactly.

**Implemented 2026-08-09**: one line — `isWaiting` in `ContentView.swift` now also ORs in
`controller.isAwaitingLoudnessAnalysis`. All three acceptance criteria fall out of the existing
`menu-bar-ui-006` debounce mechanism unchanged (same `.task(id: isWaiting)`, same 300ms show-delay/
immediate-hide asymmetry, same spinner swap on the Play/Pause button) — no new code needed beyond
the one extra condition. Reviewed manually in place of `/code-review` (no git repo yet); no issues
found.
