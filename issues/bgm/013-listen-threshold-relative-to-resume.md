---
id: bgm-013
title: Measure listen-count threshold relative to resume, not absolute position
status: done
security: false
owner: agent
depends_on: [bgm-005, bgm-012]
spec_ref: "SPEC.md#bgm-channel-playback"
---

## Description

`BGMListenTracker.start(videoID:duration:currentTime:)` (`Sources/PlaylistBar/BGMListenTracker.swift`)
currently increments a video's listen count once `currentTime()` crosses `min(30s, 20% of
duration)` — correct today since playback always starts a BGM video from 0:00. Once `bgm-012` adds
saved-position resume, a video resumed already past that absolute threshold (e.g. at 25:00 of a
30:00 video, threshold 30s) would credit a listen almost instantly, which isn't a real "listen" of
that length in this session — it should require the same `min(30s, 20%)` of actual playback
*after* resuming.

## Acceptance criteria

- Starting tracking at position 0 (today's behavior) is unaffected — threshold still fires after
  `min(30s, 20% of duration)` of playback, same as before.
- Starting tracking at a resumed non-zero position requires `min(30s, 20% of duration)` of
  *additional* playback from that position before incrementing — not instantly, even if the
  resumed position is already past the absolute threshold.
- `cancel()` still stops without incrementing, unchanged.

## Notes

Implementation approach: capture the starting position when `start()` is called and compare
*elapsed* time (`currentTime() - startPosition`) against the threshold, rather than comparing
`currentTime()` directly — no new input needed from callers, `start()`'s existing
`currentTime: () -> Double` closure is enough.

This issue's behavior only actually gets exercised once `bgm-012` lands (today `start()` is always
called at position ~0 anyway) — implement and verify both together.

## Fix / Implementation notes (2026-08-11)

`BGMListenTracker.start` gained a `startPosition: Double = 0` parameter; each poll now compares
`currentTime() - startPosition` against the threshold instead of `currentTime()` alone.

**Deviated from this issue's own Notes in one respect, for a real reason**: the Notes suggested
capturing the start position by calling `currentTime()` once inside `start()` itself. Implementing
that first and then reasoning through the actual call sequence in `PlaybackController.playBGM`
surfaced a real problem before it ever shipped: `bgmListenTracker.start(...)` is called
synchronously right after `player.load(url:duration:startTime:autoplay:)`, but `AVPlayer.seek(to:)`
(which `load` uses to honor `startTime`) is asynchronous — `player.currentTime()` generally still
reads stale/zero for a moment after `load()`/`seek()` return, before the seek actually lands. Capturing
`startPosition` via `currentTime()` at that exact synchronous point would have silently captured 0
even for a genuine resume, defeating this entire issue while still looking correct in isolated
testing. Fixed by having the caller (`PlaybackController.playBGM`, which already computes and
knows the exact `effectiveStartTime` it requested — the same value it persists via
`setLastPlayedPosition`) pass that value in explicitly, rather than trying to read it back from a
player state that hasn't caught up yet.

Verified via a standalone script covering: from-0 behavior unaffected (before/at threshold, both
the always-30s case and the 20%-of-duration case for short videos), and the issue's own example
scenario (resumed at 25:00 of a 30:00 video — 0s and 29s elapsed don't count, 30s elapsed does).
`cancel()` untouched. `swift build` passes; `swift run` launches cleanly. **Not live-verified**
(no way to observe a real BGM listen-count increment without waiting out a real video) — deferred
to a future `/qc` pass, consistent with `bgm-012`/`playback-controller-006`. `/code-review`
unavailable (same documented limitation); did a manual self-review pass instead — which is what
caught the `currentTime()`-timing issue above before it shipped.
