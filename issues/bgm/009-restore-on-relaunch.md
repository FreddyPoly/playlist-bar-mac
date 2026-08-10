---
id: bgm-009
title: Restore last-played BGM video on relaunch without auto-play
status: open
security: false
owner: agent
depends_on: [bgm-006, startup-002]
spec_ref: "SPEC.md#local-state-per-playlist"
---

## Description

Extend `startup-002`'s restore-without-autoplay behavior to cover BGM: if BGM was the last active
selection, relaunching the app shows the last-played BGM video (not a fresh pick) without starting
playback — same idle-launch guarantee the 4 fixed playlists already have.

## Acceptance criteria

- If BGM was the last active playlist-picker selection, relaunching the app restores and displays
  its last-played video (title visible, selected in the UI) without starting audio.
- Pressing Play after this restored state starts that exact video (not a new random pick) — same
  "first Play after a restore resolves and starts the displayed track" behavior
  `playback-controller-001` already has for the 4 fixed playlists.
- If BGM has never been played before, relaunching into BGM (or first selecting it ever) falls
  back to a fresh selection via `bgm-004`, same as a fixed playlist defaulting to track 1 when
  never played.

## Notes

`startup-002`'s current restore logic looks up the saved slug against the 4 hardcoded `Playlist`
entries — it will need to additionally recognize the `"bgm"` slug and route it through BGM's own
load path (`bgm-003`) rather than treating it as a missing/unknown playlist.
