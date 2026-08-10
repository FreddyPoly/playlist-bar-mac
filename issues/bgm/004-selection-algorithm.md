---
id: bgm-004
title: Fewest-listens / random-tiebreak selection algorithm
status: open
security: false
owner: agent
depends_on: [bgm-001]
spec_ref: "SPEC.md#bgm-channel-playback"
---

## Description

Implement the pure selection function that, given the current eligible BGM pool and an optional
"currently playing" video id to avoid repeating, picks the next video to play: whichever
qualifying video has the fewest local listens wins, with a uniform-random pick breaking ties among
videos sharing the minimum count.

## Acceptance criteria

- Given a pool of eligible videos with listen counts, returns one whose listen count is the
  minimum across the pool.
- When multiple videos share that minimum count, the pick is uniformly random among them (not
  always the same one, not first-in-list).
- Given a `currentVideoID` to exclude, that video is not eligible for selection even if it's tied
  for the minimum — **unless** excluding it would leave the pool empty, in which case it becomes
  eligible again (so selection never fails just because the pool has exactly one video, or every
  other video was filtered out some other way).
- Returns nothing/an appropriate "no eligible videos" result for a genuinely empty pool (distinct
  from the one-video-excluding-current case above).
- Pure function, no I/O, no side effects — doesn't itself update listen counts or persist
  anything (that's `bgm-005`/`bgm-001`).

## Notes

Mirrors this codebase's existing convention of isolating selection/skip logic as small, directly
testable pure functions (e.g. `TrackAvailabilityResolver`) rather than embedding it in the
playback controller.

The no-immediate-repeat rule (excluding the just-played video) and its "unless the pool would go
empty" fallback were both explicit decisions from the interview for this feature — don't drop
either half.
