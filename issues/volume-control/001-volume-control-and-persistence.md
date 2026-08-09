---
id: volume-control-001
title: AVPlayer volume control with persisted app-wide level
status: done
security: false
owner: agent
depends_on: []
spec_ref: "SPEC.md#local-state-per-playlist"
---

## Description

Add a settable volume level that attenuates this app's own audio output independently of the
system/macOS volume, and persist it (app-wide, not per-playlist) across quit/relaunch the same
way last-played-track and last-active-playlist already are.

## Acceptance criteria

- `AudioPlayer` exposes a volume level (0.0–1.0) applied to the underlying `AVPlayer`'s own
  `volume` property — this attenuates only this app's output, never touches the system volume or
  any other app's audio.
- Changing the level takes effect immediately on whatever's currently playing, with no audible
  glitch (no restart/reload of the current item).
- The level is persisted to disk (same Application Support directory/JSON convention as
  `PlayerStateStore`) and restored on next launch, applied before/at the point playback would
  start — so a relaunch doesn't reset to full volume.
- A newly-installed app (no prior persisted state) starts at a sensible default (100%, matching
  "no attenuation" as the natural zero-state) rather than requiring first-run configuration.

## Notes

Added 2026-08-09 after real usage: native macOS volume alone didn't give enough headroom for
comfortable listening even at its lowest setting, so this needs to be an independent attenuation
layer on top of system volume, not a wrapper around the system volume keys.

This issue is the backend piece only (player + persistence); the actual dropdown slider is
`volume-control-002`.

**Implemented 2026-08-09**: `AudioPlayer.volume` (thin wrapper over `AVPlayer.volume`, a
player-level property that survives `replaceCurrentItem` with no reload), `PlayerStateStore`
gained a `masterVolume: Double = 1.0` field with `masterVolume()`/`setMasterVolume(_:)`, and
`PlaybackController` applies the persisted value before any playback can start and exposes
`setMasterVolume(_:)` for `volume-control-002`'s slider. No git repo exists yet in this project,
so `/code-review` couldn't run automatically (documented gap) — reviewed manually instead; no
issues found.
