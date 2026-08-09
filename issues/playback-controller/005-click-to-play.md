---
id: playback-controller-005
title: Click-to-play from track list
status: done
security: false
owner: agent
depends_on: [playback-controller-001]
spec_ref: "SPEC.md#behavior-rules"
---

## Description

Clicking any track in the previous-5/next-5 track list (see menu-bar-ui-003) jumps directly to
that track and plays it immediately, updating the saved position.

## Acceptance criteria

- Clicking a listed track (not necessarily adjacent to the current one) immediately starts
  playing it.
- The clicked track becomes the new persisted last-played track for that playlist.

## Notes

Added `selectTrack(at:)` to `PlaybackController` — guards on the index being within `tracks`
bounds (no-op, not a crash, for an out-of-range or negative index), then reuses
`play(startingAt:generation:)` like everything else, so unavailable-skip/preload/persistence all
apply the same way as any other navigation.

Verified against the real Jazz playlist: `selectTrack(at: 42)` jumped directly there, started
playing, and persisted the new position correctly; both an out-of-bounds index (99999) and a
negative index correctly no-op rather than crashing.
