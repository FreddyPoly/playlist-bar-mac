---
id: volume-control-005
title: Apply per-track normalization gain alongside master trim
status: done
security: false
owner: agent
depends_on: [volume-control-001, volume-control-004]
spec_ref: "SPEC.md#volume--loudness-normalization"
---

## Description

Make actual playback use both gain stages together: the cached per-track normalization gain
(`volume-control-004`) multiplied by the app-wide master trim (`volume-control-001`), applied to
`AudioPlayer`'s underlying `AVPlayer.volume`.

## Acceptance criteria

- Effective volume set on `AVPlayer` = `masterTrim * normalizationGain` (normalization gain
  `1.0` when the current track has no cached measurement yet).
- Changing the master trim while a track plays immediately re-applies the combined effective
  volume, same "no audible glitch, no restart" behavior `volume-control-001` already requires.
- When a track starts playing with an already-cached gain (common case: analyzed on a previous
  play, or via preload/`volume-control-006`), the correct combined volume is applied from the
  first sample — no audible jump/ramp after playback starts.
- If a track's gain becomes known *while* it's already playing unnormalized (the
  `volume-control-007` fallback case resolving in the background after playback already started),
  do not retroactively change the volume mid-play — the corrected gain applies starting next time
  that track plays. (Avoids an audible volume jump partway through a track.)

## Notes

Added 2026-08-09. This is the integration point between the new normalization work and the
existing master-trim volume control — keeps `volume-control-001`'s player/persistence code
unchanged, just composes its output with the new per-track gain.

**Implemented 2026-08-09**: `PlaybackController` gained `currentTrackGain` (reads
`tracks[currentIndex].normalizationGain ?? 1.0`) and `applyEffectiveVolume()`
(`player.volume = masterVolume * currentTrackGain`), called from `init`, `setMasterVolume(_:)`,
and both places a track actually starts (`play(startingAt:generation:)`'s `.playable` case and
`advanceOnFinish`'s preloaded fast-path) — in each, right before `player.load`, so the correct
combined volume is in place before that track's audio starts. Deliberately *not* wired reactively
to `tracks` changes, so a background gain measurement landing mid-play (`volume-control-007`)
can't cause an audible jump — see the method's doc comment. Reviewed manually in place of
`/code-review` (no git repo yet); no issues found.
