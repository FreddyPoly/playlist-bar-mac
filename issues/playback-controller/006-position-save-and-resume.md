---
id: playback-controller-006
title: Persist and resume per-track seek position for the 4 fixed playlists
status: open
security: false
owner: agent
depends_on: [player-state-003, playback-engine-006, playback-controller-001]
spec_ref: "SPEC.md#local-state-per-playlist"
---

## Description

Wire `player-state-003`'s position storage and `playback-engine-006`'s seek-on-load into
`PlaybackController` for the 4 fixed playlists: save the current playback position periodically
and on key events while playing, and resume from the saved position whenever a playlist's
last-played track is (re)loaded — whether via a cold-start relaunch or switching away to a
different playlist and back within the same run.

## Acceptance criteria

- While a track plays, its position is saved roughly every 5 seconds (periodic timer, same pattern
  as `BGMListenTracker`'s existing 1Hz timer), plus immediately on pause, on switching away from
  the current playlist, and on track change (mirroring the existing
  `PlayerStateStore.setLastPlayedTrack` call sites in `play(startingAt:generation:)`).
- Switching to a playlist (via the picker) that has a saved last-played track resumes it at the
  saved position, not 0:00 — applies both right after a fresh app launch and when switching back
  to a playlist visited earlier in the same session.
- The near-end clamp (`playback-engine-006`) is honored: a saved position within ~5s of the
  track's end resumes at 0:00 instead.
- **Previous / Next / Reset still start their landed-on track at 0:00** (per SPEC.md's "Behavior
  rules") — resume-from-saved-position applies only to the "switching playlists" path, not these
  three.
- No flush-on-quit hook is added — `Quit` still calls `NSApplication.terminate(nil)` directly
  (explicit decision, see Notes); the periodic timer's ~5s granularity is the accepted loss window
  even for a clean quit.
- No new UI — no seek bar, no elapsed-time readout; this is background-only.

## Notes

Per the interview that produced this issue (`SPEC.md#local-state-per-playlist`), a clean-quit
flush hook (`applicationWillTerminate`) was explicitly considered and **rejected** in favor of
keeping the periodic-timer-only approach simple — don't add one as part of this issue.

The saved position must only be honored when it actually belongs to the track being loaded (guard
against a stale position left over from a different track under the same slug, e.g. from a write
race) — in practice this falls out naturally as long as position saves and
`setLastPlayedTrack` calls stay coupled at the same call sites.

Does not apply to BGM — see `bgm-012` for BGM's equivalent wiring (different orchestration code:
`switchToBGM`/`playBGM`/`restoreBGMSession` rather than `play(startingAt:)`).
