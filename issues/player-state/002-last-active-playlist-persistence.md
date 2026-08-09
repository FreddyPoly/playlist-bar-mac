---
id: player-state-002
title: Last active playlist persistence
status: done
security: false
owner: agent
depends_on: [player-state-001]
spec_ref: "SPEC.md#local-state-per-playlist"
---

## Description

Persist which of the 4 playlists was last active/selected, so app launch can restore the same
playlist selection (without auto-playing — see the startup feature).

## Acceptance criteria

- After selecting a playlist, relaunching the app shows that playlist selected, along with its
  last-played track (player-state-001), without starting playback.

## Notes

Extended `PlayerStateStore` (from player-state-001) with `lastActivePlaylistSlug: String?` on the
same `State` struct/file, plus `lastActivePlaylistSlug()` / `setLastActivePlaylist(slug:)`. Kept
in the same `player-state.json` rather than a separate file since both are small, related pieces
of "where the user left off" state that change together.

Verified: initially `nil` with no state file; set/read round-trips; switching the active playlist
doesn't disturb the other playlist's saved last-played track (independent from player-state-001's
map). Also verified **backward compatibility**: hand-wrote an old-format `player-state.json`
containing only `lastPlayedTrackByPlaylist` (i.e. what player-state-001 alone would have produced,
before this field existed) and confirmed it decodes without crashing — `lastActivePlaylistSlug()`
correctly returns `nil` and the pre-existing track data is still readable. This matters because a
user could genuinely have this exact file already on disk once player-state-001 ships before
player-state-002.
