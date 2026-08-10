---
id: bgm-008
title: Reset restarts the current BGM video instead of jumping
status: done
security: false
owner: agent
depends_on: [bgm-006]
spec_ref: "SPEC.md#behavior-rules"
---

## Description

For the 4 fixed playlists, Reset jumps to track 1 (`playback-controller-003`). BGM has no "track
1," so Reset instead restarts the **current** video from 0:00, leaving the selection and session
history untouched.

## Acceptance criteria

- Pressing Reset while in BGM mode restarts playback of whichever video is currently selected,
  from 0:00 — it does not pick a new video (that's what Next is for) and does not change the
  persisted last-played video (it's already the current one).
- Reset does not affect or truncate the Previous session history (`bgm-007`).

## Notes

Small, deliberate behavioral divergence from `playback-controller-003` — confirm the Reset button
in the UI (`menu-bar-ui-002`) doesn't need any visible change, since it's the controller's
handling of the Reset action that differs by mode, not the button itself.

## Implemented (2026-08-10)

Added `AudioPlayer.restart()` (`Sources/PlaylistBar/AudioPlayer.swift`) — `player.seek(to:
.zero)` followed by the existing `play()`, plus resetting `hasFiredFinishForCurrentItem` so the
end-of-track watchdog/notification can fire again for this fresh lap through the same item, in
the (unlikely) case it had already fired right as Reset was pressed. No new stream resolution or
`AVPlayerItem` — the same item stays loaded, just seeks and resumes.

`PlaybackController.reset()` branches on `isBGMActive`: when true, guards on `currentIndex != nil`
(nothing to restart otherwise), calls `player.restart()`, sets `isPlaying = true`, and returns —
no `switchGeneration` bump (nothing is being resolved asynchronously, so there's no race window to
guard against), no change to `bgmHistory`/`bgmHistoryPosition`, no re-persistence (it's already
the current track). The fixed-playlist branch is untouched.

**Verification**: `AudioPlayer.restart()`'s actual mechanic (`seek(to: .zero)` + `play()`) was
verified live against a real resolved YouTube audio stream (not simulated): played forward for
~4 real seconds, called the exact seek+play sequence, confirmed elapsed time dropped back to
under 1s (genuinely seeked, not just continuing forward), then confirmed playback resumed
advancing for real afterward (not stuck paused at 0) with `AVPlayer.rate == 1.0`. All passed.
`swift build` succeeds with no warnings. The `PlaybackController.reset()` branch itself wasn't
separately live-tested beyond code review, since it's a thin, low-risk wrapper (a guard, one
method call, one property set) around the now-live-verified `restart()`.

**Review**: manual pass in place of `/code-review` (see `bgm-002`'s Notes). `security: false` — no
new subprocess/parsing surface. No findings.
