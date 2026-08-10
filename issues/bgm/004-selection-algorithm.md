---
id: bgm-004
title: Fewest-listens / random-tiebreak selection algorithm
status: done
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

## Implemented (2026-08-10)

`Sources/PlaylistBar/BGMSelector.swift` — `BGMSelector.selectNext(from:excluding:)`: filters the
pool down by `excludingVideoID` first (falling back to the full pool if that filter would empty
it), finds the minimum `listenCount` among the remaining candidates, filters to just the ones
tied at that minimum, and returns `.randomElement()` from that tied set (Swift's
`Array.randomElement()` — uniform over the array, exactly the "uniform-random tiebreak" the spec
calls for). `nil` only when `pool` itself is empty, checked before any filtering.

**Verification**: standalone script covering every branch — empty pool → `nil`; a unique minimum
is picked deterministically; a 3-way pool with two videos tied at the minimum and one clearly
higher, sampled 500 times, both tied videos appear and the higher-count one never does (confirms
both "minimum wins" and "tiebreak is genuinely random, not first-in-array"); excluding the current
video across 200 samples never returns it while an alternative exists; a single-video pool still
returns that video even when it's the one being excluded (the empty-pool fallback); excluding a
video id that isn't even in the pool is a harmless no-op, leaving all real candidates eligible.
All passed. `swift build` succeeds with no warnings.

**Review**: manual pass in place of `/code-review` (see `bgm-002`'s Notes). Pure function, no I/O,
no shared/mutable state — no findings.
