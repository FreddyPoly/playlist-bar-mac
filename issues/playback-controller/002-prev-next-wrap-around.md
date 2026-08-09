---
id: playback-controller-002
title: Previous/Next with wrap-around
status: done
security: false
owner: agent
depends_on: [playback-controller-001, player-state-001]
spec_ref: "SPEC.md#behavior-rules"
---

## Description

Implement Previous/Next transport actions that step by playlist index and wrap around at either
end (Previous on track 1 jumps to the last track; Next on the last track jumps to track 1),
updating the persisted last-played-track state on every step.

## Acceptance criteria

- Pressing Next repeatedly through an entire playlist eventually wraps back to track 1.
- Pressing Previous on track 1 jumps to the last track.
- Each step (Previous or Next) updates the saved position (player-state-001) immediately.

## Notes

Added `previous()`/`next()` directly to `PlaybackController` (same file/class from
playback-controller-001, rather than a new file — these are just more methods on the one
controller that the whole `playback-controller` feature builds up incrementally). Both funnel
through a new private `step(by:)` helper that computes the wrapped index
(`((current + offset) % count + count) % count`, correct for the -1 case in Swift where `%` can
return negative) and reuses the existing `play(startingAt:generation:)` from
playback-controller-001 — so a step that lands on a currently-unavailable track transparently
skips further via `TrackAvailabilityResolver`, same as the initial switch-to-playlist case. Also
reuses the existing `switchGeneration` race guard (broadened its doc comment slightly since it
now guards more than just `switchTo`).

Verified against the real Jazz playlist (178 tracks):
- `next()` from track 0 → track 1; `previous()` back to track 0 — both persisted correctly via
  `PlayerStateStore` at each step.
- `previous()` from track 0 → wrapped to the last track (index 177); `next()` from there →
  wrapped back to track 0 — confirms both wrap directions.
- Raced two `next()` calls back-to-back without awaiting the first — final state was a single,
  valid, non-corrupted index (not `nil`, not a torn/inconsistent value), confirming the shared
  generation guard also protects prev/next against the same race class covered for `switchTo`.

Did not re-run the full-playlist-cycle sanity check (178 consecutive `next()` calls returning to
the start) — each call does a real yt-dlp resolve (~1-2s), making that prohibitively slow for a
verification pass; the two wrap-boundary tests above already exercise the actual wrap-around
logic directly.
