---
id: bgm-005
title: Listen-count increment on playback threshold
status: open
security: false
owner: agent
depends_on: [bgm-001, playback-engine-002]
spec_ref: "SPEC.md#bgm-channel-playback"
---

## Description

Increment a BGM video's local listen count once continuous playback of it passes
`min(30s, 20% of its duration)` — long enough that an accidental skip doesn't inflate the count,
short enough not to require finishing a long track.

## Acceptance criteria

- A video's listen count increments exactly once per play that crosses the threshold — not on
  every progress tick past it, and not again if playback continues well past the threshold.
- A play that's abandoned (skipped, playlist switched away, app quit) before reaching the
  threshold does **not** increment the count.
- The threshold is `min(30s, 20% of duration)` — e.g. a 20-minute video's threshold is 30s (since
  20% of 1200s = 240s > 30s), while a 16-minute video's threshold is also 30s; only a video short
  enough that 20% of its duration is under 30s would use the smaller value. (Given the 15-minute
  minimum for pool eligibility, 30s will be the effective threshold for essentially every real
  BGM video — still implement the formula as specified, not a hardcoded 30s.)
- The increment is persisted immediately via `bgm-001`'s storage, not just held in memory.

## Notes

Needs some form of playback-progress observation against the resolved stream's real duration —
reuse whatever time-tracking `playback-engine-002`'s `AudioPlayer` already exposes (or the
trusted-duration watchdog from `playback-engine-005`) rather than introducing a second, competing
notion of "how far into this track are we."

This only needs to fire for BGM videos — regular fixed-playlist tracks have no listen-count
concept and shouldn't be affected by this issue.
