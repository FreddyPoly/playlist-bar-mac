---
id: playback-engine-003
title: Next-track preloading
status: done
security: false
owner: agent
depends_on: [playback-engine-001, playback-engine-002]
spec_ref: "SPEC.md#playback-engine"
---

## Description

While a track is playing, resolve the stream URL for the next track (per playlist order, with
wrap-around at the end) in the background ahead of time, so auto-advance has no perceptible
resolution delay. Cancel/discard an in-flight or completed preload if the user navigates away
from the track it was computed for before it's used.

## Acceptance criteria

- Starting playback of track N triggers a background resolve for track N+1 (or track 1 if N is
  the last track).
- When track N finishes naturally, track N+1 begins playing immediately using the preloaded URL
  rather than re-resolving from scratch.
- If the user manually jumps elsewhere (prev/next/track click) before the preload for the
  "expected next" track completes or is used, the stale preload is discarded rather than
  incorrectly applied to the wrong track.

## Notes

Builds on playback-engine-001's resolution function (already flagged security-sensitive); this
issue is scheduling/cancellation logic only, no new untrusted-input handling.

Implemented as `NextTrackPreloader` in `Sources/PlaylistBar/NextTrackPreloader.swift`:
`beginPreload(tracks:currentIndex:)` computes the wrap-around next index and kicks off a
`Task.detached` resolve for it; `takePreloadedURL(for:)` returns (and consumes) the result only if
it matches the requested video id, otherwise `nil` so the caller falls back to a fresh resolve;
`cancel()` discards any in-flight or completed preload. Calling `beginPreload` again before a
prior preload is consumed implicitly cancels it (covers the "user navigates away" case without a
separate method).

This issue only builds the preload *mechanism* — actually wiring it into auto-advance (calling
`beginPreload` when a track starts, and `takePreloadedURL` from the finish callback) is
playback-controller-004's job, since that's where playlist order/current-index state actually
lives (via playback-controller-001).

Verified against real tracks (Jazz playlist's first 3), all via the real `StreamResolver`:
- `beginPreload(currentIndex: 0)` correctly targets track 1; `beginPreload(currentIndex: 2)`
  (last index of 3) correctly wraps to track 0.
- After letting a real background resolve complete (~2s, matching live resolution time),
  `takePreloadedURL` itself returned in **5 microseconds** — direct evidence it's returning an
  already-resolved URL rather than re-resolving, which is the whole point of preloading.
- `takePreloadedURL` for the wrong video id correctly returned `nil` rather than misapplying a
  ready preload to an unrelated track.
- A second `beginPreload` call before the first's result was consumed correctly discarded the
  first target — the old target's `takePreloadedURL` returned `nil` even after waiting, while the
  new target's returned a real URL — confirming the "navigated away" cancellation behavior.
- `cancel()` immediately clears `preloadedVideoID`, and even after waiting past when the
  in-flight resolve would have completed, `takePreloadedURL` still correctly returned `nil`.
