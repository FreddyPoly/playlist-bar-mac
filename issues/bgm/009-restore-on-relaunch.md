---
id: bgm-009
title: Restore last-played BGM video on relaunch without auto-play
status: done
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

## Implemented (2026-08-10)

`restoreLastSession()` now checks the saved slug against `Self.bgmPlaylistSlug` first and routes
to a new `restoreBGMSession()` before falling through to the existing `FixedPlaylists.all` lookup.
`restoreBGMSession()` loads the pooled cache (cache-first, via `bgmLoader`), resolves the
persisted last-played video (or a fresh `BGMSelector` pick if there isn't one), and populates
`tracks`/`currentIndex`/`currentPlaylist` for display — deliberately **never** calling
`player.load`/setting `isPlaying`/setting `hasLoadedCurrentTrack`, mirroring
`loadAndDetermineStartIndex`'s same "restore for display only" contract. Also seeds
`bgmHistory = [restoredTrack]`, so the restored track is correctly the one (and only) history
entry rather than leaving history empty while something is already "current."

**Closed a gap `bgm-006` explicitly flagged**: `togglePlayPause()`'s fallback branch (for when
`currentIndex` is set but `hasLoadedCurrentTrack` is false — exactly the state
`restoreBGMSession()` produces, and the *only* way that state becomes reachable for BGM, since
`switchToBGM()` always autoplays) previously called the fixed-playlist `play(startingAt:)`
unconditionally. That would have "worked" in the sense of not crashing, but would have bypassed
`BGMCacheStore`'s gain persistence, `bgmHistory` bookkeeping, and `bgmListenTracker`, and would
have fed a BGM track through `LoudnessGainCoordinator`/`NextTrackPreloader` — silently discarding
any gain measurement, per `bgm-006`'s own Notes on why those can't be reused as-is for BGM. Added
an `isBGMActive` branch that instead looks up the displayed track in `bgmLoader.tracks` and routes
through `playBGM(startingFrom:generation:appendToHistory: false)` — the `false` matters here since
`restoreBGMSession()` already seeded this track into `bgmHistory`, so playing it for the first
time must not duplicate it. Bails cleanly (no play) if the video is no longer in the pool by the
time Play is pressed (e.g. a background refresh dropped it in between) rather than guessing at an
unknown duration for the listen tracker.

**Verification**: standalone script mirroring the real control flow (restore, first Play press,
subsequent pause/resume toggles, and a no-saved-video fallback) confirmed: restoring with a saved
video displays it without auto-playing or marking it loaded; the restored track is seeded as the
sole history entry; the first Play press afterward resolves and starts *that exact* track (not a
fresh random pick), correctly avoids duplicating it in history, persists it as last-played, and
makes only one resolve call; subsequent pause/resume toggles don't trigger any further resolves;
and restoring with no saved video at all falls back to a pool pick rather than leaving a blank/
stuck state. All passed. `swift build` succeeds with no warnings.

**Review**: manual pass in place of `/code-review` (see `bgm-002`'s Notes). `security: false` — no
new subprocess/parsing surface; reuses already-reviewed `bgmLoader`/`playBGM`/`BGMSelector`. No
findings.
