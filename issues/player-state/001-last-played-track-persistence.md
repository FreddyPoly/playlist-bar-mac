---
id: player-state-001
title: Per-playlist last-played-track persistence
status: done
security: false
owner: agent
depends_on: []
spec_ref: "SPEC.md#local-state-per-playlist"
---

## Description

Persist, per playlist, the video id of the last-played track, updated on every track change
(play, prev, next, reset, or track click). Store as local JSON under
`~/Library/Application Support/PlaylistBar/` (separate from playlist-data's track-list cache).

## Acceptance criteria

- After playing/skipping to a track, the choice is persisted immediately (not just in memory).
- Relaunching the app and switching to a playlist resumes at the exact track last played on it.
- A playlist never played before defaults to track 1 when first selected.

## Notes

App-generated data only (video ids the app itself selected) — no external/untrusted input
involved in this issue.

Implemented as `PlayerStateStore` in `Sources/PlaylistBar/PlayerState.swift`: a simple
`[playlistSlug: videoID]` map, stored as `player-state.json` under
`~/Library/Application Support/PlaylistBar/` (a separate file from `PlaylistCacheStore`'s track
lists, since this changes on every track change rather than every 24h scan). Atomic writes, same
pattern as `PlaylistCacheStore`. `lastPlayedTrack(forPlaylistSlug:)` returns `nil` for a playlist
never played before, matching this issue's "default to track 1" requirement (that default is the
caller's job — playback-controller-001 — not this storage layer's).

Verified: setting/reading round-trips correctly, different playlists are tracked independently
(setting one doesn't affect another), overwriting an existing value works, and — to prove this is
real disk persistence rather than just in-process state — read the value back from a **second,
separate `swift` process** after the first had written it, confirming it survives what a real app
quit/relaunch would look like.
