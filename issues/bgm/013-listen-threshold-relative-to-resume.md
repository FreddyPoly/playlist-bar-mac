---
id: bgm-013
title: Measure listen-count threshold relative to resume, not absolute position
status: open
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
