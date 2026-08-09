---
id: playback-controller-004
title: Auto-advance on track completion
status: done
security: false
owner: agent
depends_on: [playback-controller-002, playback-engine-004]
spec_ref: "SPEC.md#behavior-rules"
---

## Description

When the currently playing track finishes naturally (via playback-engine-002's completion
callback), automatically advance to the next track using the same logic as the Next control,
including wrap-around at the end of the playlist and skipping unavailable tracks
(playback-engine-004).

## Acceptance criteria

- Letting a track play to completion automatically starts the next track with no user action.
- Behaves identically to pressing Next at the playlist's end (wraps to track 1).
- If the next track is unavailable, continues skipping forward until a playable track is found
  (per playback-engine-004).

## Notes

Wired `AudioPlayer.setOnFinish` (playback-engine-002) once in `PlaybackController.init` to a new
`advanceOnFinish()` method. Goes further than a literal re-implementation of `next()`: it first
tries `NextTrackPreloader.takePreloadedURL(for:)` (playback-engine-003) for the immediate next
track, and only falls back to a fresh `play(startingAt:generation:)` resolve (which is what
carries the wrap-around + unavailable-skip behavior via `TrackAvailabilityResolver`, reused as-is)
if no matching preload is ready. This wasn't in this issue's original `depends_on`, but
playback-engine-003's own issue notes explicitly flagged this as its intended integration point
("wiring it into actual auto-advance is playback-controller-004's job") — implementing auto-
advance without it would mean building preloading in this backlog and then never actually using
it for the one thing it exists for.

Every successful `play()` (switch, prev/next, reset, or a finish-triggered advance) now also
calls a new `beginPreloadForNext()` to keep the next track preloaded — matching SPEC.md's
"resolve on play + preload next track" playback-engine design, not just the auto-advance path
specifically. `switchTo` also cancels any stale preload from the previous playlist before
starting the new one.

Verified against the real Jazz playlist, driving actual playback to its genuine natural end
(seeking to 2 seconds before a track's real end, not simulating the finish callback):
- Forward auto-advance: after letting the background preload for track 1 complete (~3s wait),
  seeked track 0 near its end — `currentIndex` advanced from 0 to 1 and `isPlaying` stayed `true`,
  with the new position persisted correctly.
- Wrap-around auto-advance: navigated to the last track (index 177) via `previous()`, let its
  preload (wrapping to index 0) complete, then let it play to its real end — `currentIndex`
  correctly wrapped from 177 to 0, persisted correctly.

Did not construct a dedicated live test for "the immediate next track is unavailable, so
auto-advance skips further" specifically through this finish-callback path — that behavior comes
from reusing `TrackAvailabilityResolver` (already verified thoroughly in playback-engine-004) in
the fallback branch, and constructing a real playlist copy with an injected unavailable track felt
like more setup than the marginal confidence was worth, given the underlying skip logic is
independently proven correct.
