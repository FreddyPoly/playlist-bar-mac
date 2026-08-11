---
id: playback-controller-006
title: Persist and resume per-track seek position for the 4 fixed playlists
status: done
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

## Fix / Implementation notes (2026-08-11)

Added a `PlaybackController`-lifetime (not per-track) periodic `Timer` (`positionSaveInterval =
5.0`, same `Timer` + `RunLoop.main.add(_:forMode:)` + `Task { @MainActor in }` pattern as
`BGMListenTracker`), gated in its callback on `isPlaying`; a shared `savePosition()` helper (also
gated on `!isBGMActive`/`hasLoadedCurrentTrack`) is additionally called explicitly on pause
(`togglePlayPause()`), and on switching away from the current playlist (top of `switchTo(playlist
:)`/`switchToBGM()`, before any state mutation, so it captures the *outgoing* playlist's live
position). Track-change saves (`setLastPlayedPosition(0, ...)`) were added next to both existing
`setLastPlayedTrack` call sites for the non-resume paths — `play(startingAt:generation:)`'s
success case and `advanceOnFinish`'s preloaded fast path.

`play(startingAt:generation:resumePosition:)` gained the `resumePosition` parameter (default
`false`), passed `true` only by `switchTo(playlist:)` and `togglePlayPause()`'s post-restore
fallback (the cold-start-relaunch case) — every other caller (`step`/`reset`/`selectTrack`/
`advanceOnFinish`'s fallback) keeps the default, so Previous/Next/Reset/track-click/auto-advance
all still start at 0:00 per SPEC.md's "Behavior rules". When `resumePosition` is true, the saved
position is only actually honored if `PlayerStateStore.lastPlayedTrack(forPlaylistSlug:)` still
matches the *resolved* track's video id — guards against `TrackAvailabilityResolver` auto-skipping
to a different track (the original became unavailable) inheriting a stale position that belongs to
a different video, per this issue's own Notes above.

`AudioPlayer.nearEndClampSeconds` was widened from `private` to internal so `PlaybackController`
could predict the same near-end-clamp decision `AudioPlayer.load` makes internally — without this,
persisting `startTime` as-is for a clamped (near-end) resume would leave a briefly-wrong position
on disk (the track actually started at 0:00, not the pre-clamp value) until the next periodic save
corrected it a few seconds later; found and fixed during this issue's own self-review, verified via
the standalone script below.

Verified: `swift build` passes; a standalone script (mirroring the two pure decision points —
the video-id resume guard and the near-end-clamp persistence prediction — since the real logic
lives in `@MainActor` methods wired to `AVPlayer`/yt-dlp/`PlayerStateStore` and isn't callable
standalone) covers resume-honored/ignored-on-mismatch/ignored-when-not-requested/ignored-when-
nothing-saved, plus clamp-vs-no-clamp persistence. `swift run` launches cleanly with no crash.
**Not live-verified** (actually switching playlists in the running app and confirming audible
resume-from-position) — this project's established pattern for GUI-observable behavior is a
human-driven `/qc` pass (see CLAUDE.md's "Known gaps" note on visual/interactive verification);
flagging this explicitly rather than claiming untested behavior works. `/code-review` unavailable
for the same reason as every other issue here (agent-invocable only via explicit user run, no
GitHub remote) — did a manual self-review pass instead.
