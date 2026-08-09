---
id: volume-control-006
title: Fold loudness analysis into next-track preloading
status: done
security: false
owner: agent
depends_on: [volume-control-003, volume-control-004]
spec_ref: "SPEC.md#volume--loudness-normalization"
---

## Description

Extend `NextTrackPreloader` (`playback-engine-003`) so that, alongside its existing background
stream-URL resolution for the next track, it also triggers loudness analysis for that track if
it isn't already cached — so normal forward listening (auto-advance, Next) never waits on
analysis.

## Acceptance criteria

- When `NextTrackPreloader` resolves the next track's stream in the background, it also checks
  for a cached normalization gain (`volume-control-004`) and, if missing, runs the analysis
  (`volume-control-003`) in that same background window.
- By the time playback naturally reaches that track (auto-advance or Next), its gain is already
  cached and applied with no added delay — matches the existing "effectively gapless" guarantee
  `playback-engine-003` already provides for stream resolution.
- If analysis doesn't finish before playback reaches that track anyway (e.g. an unusually short
  current track), playback proceeds via the same fallback path as `volume-control-007` — this
  issue only adds the head start, it doesn't introduce a second blocking wait.
- Preloading a track whose gain is already cached skips the analysis step entirely (no redundant
  `ffmpeg` call).

## Notes

Added 2026-08-09. Purely a background-scheduling extension of existing preload machinery — no
new UI, no change to `volume-control-003`'s measurement logic itself.

**Implemented 2026-08-09**: this turned out to need a small shared piece,
`LoudnessGainCoordinator` (new file), because the spec's own fallback note ("if analysis doesn't
finish in time... proceeds via the same fallback path as volume-control-007") only actually holds
if analysis-in-progress is never cancelled just because a caller stopped waiting on it — otherwise
an unlucky short current track would permanently lose that track's analysis instead of just
missing it once. The coordinator tracks at most one in-flight analysis per video id
(`beginAnalysisIfNeeded`, used here for the fire-and-forget preload case) and a separate bounded
`gain(for:url:playlistSlug:timeout:)` (used by `volume-control-007`) that races the analysis
against a timeout without cancelling the loser. `NextTrackPreloader.beginPreload` now also takes
`playlistSlug`/`loudnessCoordinator` and calls `beginAnalysisIfNeeded` right after resolving the
next track's stream URL. `PlaybackController` wires `loudnessCoordinator.onGainMeasured` to update
its in-memory `tracks` array (the disk cache is already updated by the coordinator itself) —
`volume-control-005`'s `applyEffectiveVolume()` then just reads whatever's there, deliberately not
triggered reactively by this update (no mid-track volume jump).

**Verification**: the coordinator's race logic (fast measurement wins, slow measurement loses to
timeout but keeps running and still reports afterward, failure falls back like a timeout) was
verified via a standalone script with a fake delayed "measurement" in place of real `ffmpeg` (not
installed on this machine yet — see `volume-control-003`'s Notes). Reviewed manually in place of
`/code-review` (no git repo yet); no issues found.
