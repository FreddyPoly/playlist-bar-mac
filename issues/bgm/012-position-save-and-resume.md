---
id: bgm-012
title: Persist and resume BGM's saved seek position
status: done
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

## Fix / Implementation notes (2026-08-11)

`PlaybackController.savePosition()` (added by `playback-controller-006`) turned out to already be
playlist-agnostic — it only ever read `currentPlaylist?.slug`/`hasLoadedCurrentTrack`, both shared
by BGM's synthetic playlist representation — so the one-line fix was removing its `!isBGMActive`
guard rather than writing a second, near-duplicate BGM-specific save function. This alone gives
BGM the periodic 5s save (same timer) and the on-pause save (`togglePlayPause()`'s pause branch
already called `savePosition()` unconditionally) for free. The on-switch-away save was likewise
already covered: `switchTo(playlist:)` (switching away *from* BGM) and `switchToBGM()` (switching
away from a fixed playlist *to* BGM) both already call `savePosition()` as their first line.

`playBGM(startingFrom:generation:appendToHistory:resumePosition:)` gained the `resumePosition`
parameter (default `false`, mirroring `play(startingAt:generation:resumePosition:)`), passed
`true` from both of `switchToBGM()`'s call sites and from `togglePlayPause()`'s post-restore BGM
fallback — `advanceBGM`/`previousBGM`/`selectBGMHistoryEntry` all keep the default, so Next/
Previous/history-click still start at 0:00. When honored, resume is only actually applied if
`PlayerStateStore.lastPlayedTrack(forPlaylistSlug: "bgm")` still matches the video actually played
— same stale-position guard as the fixed-playlist path, needed here too since `playBGM`'s own
retry-on-unavailable loop can swap `candidate` mid-call. The same near-end-clamp persistence
prediction as `playback-controller-006` was added (using the same now-internal
`AudioPlayer.nearEndClampSeconds`) so a clamped resume persists 0, not the pre-clamp `startTime`.

Verified `startTrack`'s two paths in `switchToBGM()`: passing `resumePosition: true` unconditionally
from both is safe even though one is "found in `bgmHistory`" and the other is "fresh pick, first
switch this session" — in both cases `startTrack` is *either* the actual persisted last-played
video (in which case resuming is correct) *or* a freshly-`BGMSelector`-picked video (in which case
the internal video-id-match guard naturally no-ops, since a fresh pick's id won't equal the saved
one). Confirmed by re-reading `switchToBGM()`'s existing logic rather than by a live run.

Deliberately did **not** touch `BGMListenTracker`'s threshold logic or its `bgmListenTracker.start(
...)` call site here — `bgm-013` (implemented immediately after this issue, per this issue's own
Notes above requiring them to land together) owns making the threshold relative to the resume
offset rather than absolute position.

Verified: `swift build` passes; the same standalone script from `playback-engine-006`/
`playback-controller-006` covers the shared decision formulas (video-id resume guard, near-end-
clamp persistence prediction) since BGM's `playBGM` uses byte-for-byte the same logic; `swift run`
launches cleanly. **Not live-verified** for the same reason as `playback-controller-006` — deferred
to a future `/qc` pass. `/code-review` unavailable (same documented limitation); did a manual
self-review pass instead.
