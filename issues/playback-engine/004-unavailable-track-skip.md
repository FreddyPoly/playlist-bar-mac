---
id: playback-engine-004
title: Unavailable-track auto-skip
status: done
security: false
owner: agent
depends_on: [playback-engine-001, playback-engine-003]
spec_ref: "SPEC.md#behavior-rules"
---

## Description

When resolving or playing a track fails because it's unavailable (per playback-engine-001's
"unavailable" result), automatically advance to the next track (respecting wrap-around) instead
of stopping playback.

## Acceptance criteria

- Attempting to play or auto-advance into a video id that yt-dlp reports as unavailable results
  in playback moving on to the following track without user intervention.
- This does not crash or hang the app, and does not get stuck in an infinite loop if multiple
  consecutive tracks are unavailable (eventually either plays a valid track or, if literally every
  track in the playlist is unavailable, stops gracefully with no crash).

## Notes

Control-flow logic only; the underlying untrusted-data handling is already covered by
playback-engine-001.

Implemented as `TrackAvailabilityResolver.resolveNextPlayable(tracks:startIndex:)` in
`Sources/PlaylistBar/TrackAvailabilityResolver.swift`. Tries `tracks[startIndex]`, then each
subsequent track in order with wrap-around, for at most `tracks.count` attempts total — bounding
the loop structurally (a `for` loop over a fixed range) rather than relying on any other
termination condition, so it's impossible for this to spin forever even if every track in the
playlist is unavailable. A resolution failure that *isn't* "unavailable" (yt-dlp missing, a
transient process error) is treated as a systemic problem and propagates immediately via Swift's
normal `throws` mechanism, rather than being swallowed and retried across every remaining track —
matches playback-engine-001's intent of letting callers distinguish the two failure modes.

Verified against real video ids (mixing real Jazz-playlist tracks with confirmed-unavailable fake
ids):
- First track already available → returned immediately with no skipping.
- First track unavailable, second available → correctly skipped to index 1.
- Both tracks in a 2-track list unavailable → correctly returned `.noneAvailable` in ~1.1s (two
  resolutions' worth of time), not a hang — directly demonstrates the bounded-loop guarantee.
- Wrap-around: starting at the last index of a 3-track list (unavailable) correctly wrapped to
  index 0 (available) rather than stopping at the list's edge.
- Empty track list → returned `.noneAvailable` immediately without crashing.

Did not construct a case exercising the "non-unavailable error propagates instead of being
skipped" path — doing so would need either a way to force a non-"Video unavailable" yt-dlp
failure on demand, or dependency-injecting `StreamResolver` behind a protocol/closure, which felt
like more surface area than this issue's scope justified. Confidence here rests on the `throws`
propagation being a straightforward language guarantee (the `try await` inside the loop isn't
caught anywhere before the function's own `throws` boundary), not on empirical testing — flagging
this honestly rather than implying it was verified the same way the rest of this issue was.
