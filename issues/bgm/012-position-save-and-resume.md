---
id: bgm-012
title: Persist and resume BGM's saved seek position
status: open
security: false
owner: agent
depends_on: [player-state-003, playback-engine-006, bgm-006, bgm-009]
spec_ref: "SPEC.md#local-state-per-playlist"
---

## Description

BGM equivalent of `playback-controller-006`: save BGM's current playback position periodically and
on key events while playing, and resume from the saved position whenever BGM's last-played video
is (re)loaded — via `switchToBGM()`, `restoreBGMSession()`, or the `togglePlayPause()` fallback
path that replays a restored-but-not-yet-loaded BGM track (`bgm-009`'s wiring).

## Acceptance criteria

- Position is saved roughly every 5 seconds while a BGM video plays, plus on pause and on
  switching away from BGM — same cadence as `playback-controller-006`, stored under BGM's `"bgm"`
  playlist slug via `player-state-003`'s API.
- Resuming BGM's last-played video (relaunch, or switching away to a fixed playlist and back)
  starts at the saved position instead of 0:00.
- The near-end clamp (`playback-engine-006`) applies: a saved position within ~5s of the video's
  duration resumes at 0:00 instead.
- **Reset still restarts the current video at 0:00** (per SPEC.md's "Behavior rules" — BGM's Reset
  is unchanged by this issue) and **Next/Previous still start the newly-selected/history video at
  0:00** — resume-from-saved-position applies only to re-loading the *same* last-played video, not
  to picking a different one.
- Does not change BGM's dropped per-track loudness normalization (`playBGM` still constructs with
  `normalizationGain: nil`) — resuming a position is independent of that.

## Notes

BGM's videos run 15 minutes to over an hour, so this matters more here than for the 4 fixed
playlists' typically few-minute tracks — this was the main reason BGM was included in scope at
all rather than fixed-playlists-only (see the interview decision in
`SPEC.md#local-state-per-playlist`).

Resuming mid-video interacts with `BGMListenTracker`'s listen-count threshold — see `bgm-013`,
which must land alongside this issue so resuming late into a long video doesn't instantly credit a
listen just because the resumed position already happens to be past the threshold.

No flush-on-quit hook, same explicit decision as `playback-controller-006`.
