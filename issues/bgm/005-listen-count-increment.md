---
id: bgm-005
title: Listen-count increment on playback threshold
status: done
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

## Implemented (2026-08-10)

Added a small `currentTime: Double` getter to `AudioPlayer` (`Sources/PlaylistBar/AudioPlayer.swift`)
— a thin pass-through to `CMTimeGetSeconds(player.currentTime())`, the same underlying state the
existing end-of-track watchdog already reads, so this isn't a second/competing notion of playback
position.

`Sources/PlaylistBar/BGMListenTracker.swift` — `BGMListenTracker`: `start(videoID:duration:
currentTime:)` computes `min(30, duration * 0.2)`, arms a 1Hz `Timer` (same
`Timer(timeInterval:repeats:)` + `RunLoop.main.add(timer, forMode: .common)` +
`Task { @MainActor in ... }` pattern as `AudioPlayer`'s own watchdog, for consistency), and once
`currentTime()` crosses the threshold, calls `BGMCacheStore.incrementListenCount(forVideoID:)`
and stops itself — a genuine one-shot, not a repeating increment. `cancel()` stops tracking
without incrementing. `start()` always cancels any prior in-flight tracking first, so switching to
a new BGM video before the previous one's threshold is a no-op for the abandoned one automatically.

**Important wiring note for `bgm-006`** (not this issue's scope, but load-bearing): `start()`'s
auto-cancel only covers switching *between* BGM videos. Switching away from BGM to one of the 4
fixed playlists must **explicitly** call `cancel()` too — otherwise a still-armed tracker would
keep polling `currentTime()` against whatever `AudioPlayer` now has loaded (a different playlist's
track) and could misattribute a listen to the BGM video that's no longer playing. Flagging this
prominently since it's an easy thing to silently miss when wiring `bgm-006`.

**Verification**: the pure threshold formula (900s/1200s videos → 30s; a hypothetical 100s video →
20s, confirming the formula itself, not a hardcoded 30, is what's implemented) plus a **live**
end-to-end test using the real `Timer`/`RunLoop`/`MainActor`-hop mechanics (not a logic-only
stand-in): a short-duration (5s → 1s threshold) tracked video genuinely increments the real
on-disk cache once real wall-clock time and a real scheduled `Timer` fire, does not fire a second
time afterward, `cancel()` before the threshold prevents any increment even after more time
passes, and starting a new video cancels a still-pending previous one so it never fires late. All
passed. `swift build` succeeds with no warnings (an initial version produced a MainActor-isolation
warning calling `cancel()` directly from the Timer's synchronous callback; fixed by hopping via
`Task { @MainActor in ... }`, the same pattern `AudioPlayer`'s watchdog already uses — caught
during this issue's own build-and-review pass, not a separate finding).

**Review**: manual pass in place of `/code-review` (see `bgm-002`'s Notes). `security: false` — no
new subprocess/parsing surface. No findings beyond the isolation warning above, which was fixed
before this was marked done.
