---
id: playback-controller-003
title: Reset control
status: done
security: false
owner: agent
depends_on: [playback-controller-002]
spec_ref: "SPEC.md#behavior-rules"
---

## Description

Implement the Reset control: jump to track 1 of the current playlist and play it, updating the
saved position.

## Acceptance criteria

- Pressing Reset from any position in the playlist starts playing track 1 immediately.
- The new position (track 1) is persisted as the last-played track for that playlist.

## Notes

Added `reset()` to `PlaybackController`: guards on an empty track list (no-op if no playlist is
active yet, rather than crashing), then reuses the same `play(startingAt: 0, generation:)` helper
as everything else in this controller.

Verified against the real Jazz playlist: advanced 3 tracks via `next()`, called `reset()`, and
confirmed it jumped to index 0, started playing (`isPlaying == true`), and persisted track 0 as
the new saved position. Also verified calling `reset()` on a controller that never had
`switchTo` called (empty track list) safely no-ops rather than crashing.
