---
id: playback-controller-001
title: Playlist switch orchestration
status: done
security: false
owner: agent
depends_on: [playlist-data-003, playback-engine-002, player-state-001]
spec_ref: "SPEC.md#behavior-rules"
---

## Description

Implement "switch to playlist X": load its cached track list (playlist-data-003), look up its
saved last-played track (player-state-001) or default to track 1 if never played, and start
playback immediately — stopping whatever was previously playing.

## Acceptance criteria

- Selecting a different playlist stops current playback and immediately starts playing the
  target playlist's saved (or first) track.
- Only one playlist plays at a time; there is never overlapping audio from two playlists.
- Switching to a playlist not yet cached shows a loading state and starts playback as soon as
  data is available, rather than blocking indefinitely with no feedback.

## Notes

Pure orchestration of already-covered lower-level pieces (cache load, state lookup, playback) —
no new untrusted-input handling introduced here.

Introduced `Playlists.swift` (the `Playlist` model and `FixedPlaylists.all` — the app's 4 fixed
playlists with slug/name/URL, transcribed from SPEC.md) and `PlaybackController.swift`, an
`ObservableObject` publishing `currentPlaylist`, `tracks`, `currentIndex`, `isLoading`, and
`isPlaying`. `switchTo(playlist:)` stops current playback, loads via `PlaylistLoader`
(playlist-data-003), looks up the saved position via `PlayerStateStore` (player-state-001/002) or
defaults to index 0, and plays via `TrackAvailabilityResolver.resolveNextPlayable`
(playback-engine-004) rather than a raw `StreamResolver.resolve` — so if the saved/first track
happens to be unavailable now (e.g. deleted since last played), it transparently skips to the
next playable one instead of failing to start at all.

A `switchGeneration` counter guards against a fast second `switchTo` call superseding a first one
still in flight — without it, the first call's result could land *after* the second call's and
silently overwrite the correct final state.

`isPlaying`/`isLoading` are managed directly by the controller around its own await boundaries
(set true/false at the points it calls into `loader`/`player`) rather than living-forwarded via a
Combine subscription from `PlaylistLoader`'s own published state. This means a background refresh
that completes *after* a switch (playlist-data-003's stale-cache case) updates `PlaylistLoader`'s
internal state but won't currently propagate into this controller's `tracks` for an
already-displayed playlist — acceptable for this issue's acceptance criteria (which only concern
the switch itself), but worth revisiting when menu-bar-ui-003 is built if a live-updating track
list turns out to matter in practice.

Verified end-to-end against the real Jazz and Tranquille playlists:
- First-ever switch to Jazz (never played before): loaded all 178 tracks, defaulted to
  `currentIndex: 0`, `isPlaying` became `true`, and both `PlayerStateStore` entries (last-played
  track, last active playlist) were correctly persisted.
- Manually recorded track index 5 as Jazz's saved position, switched away to Tranquille (first
  time — correctly defaulted to index 0, confirming per-playlist independence and that switching
  stopped the previous playlist's playback) and back to Jazz — **correctly resumed at index 5**,
  not a restart at track 0.
- Raced two `switchTo` calls back-to-back without awaiting the first (`switchTo(tranquille)` then
  immediately `switchTo(jazz)`) — final state correctly reflected the second call, confirming the
  `switchGeneration` guard prevents a stale race from corrupting state.
