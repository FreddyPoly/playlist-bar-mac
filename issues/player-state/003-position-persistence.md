---
id: player-state-003
title: Per-playlist last-played seek-position persistence
status: open
security: false
owner: agent
depends_on: [player-state-001]
spec_ref: "SPEC.md#local-state-per-playlist"
---

## Description

Extend `PlayerStateStore` (`Sources/PlaylistBar/PlayerState.swift`) to persist, per playlist slug,
the elapsed seek position (seconds) within the last-played track — alongside the existing
last-played video id from `player-state-001`. One value per playlist slot (the 4 fixed playlists
plus BGM's `"bgm"` slug), overwritten every time the position is saved for that slot — not a
history of positions per track. Storage only: write cadence (periodic + event-driven) and applying
the saved position on load belong to `playback-controller-006` (fixed playlists) and `bgm-012`
(BGM).

## Acceptance criteria

- A new `lastPlayedPositionByPlaylist: [String: Double]` (or equivalent) field on the persisted
  `State`, with `lastPlayedPosition(forPlaylistSlug:)` (returns `nil`/`0` if never saved) and
  `setLastPlayedPosition(_:forPlaylistSlug:)` accessors, mirroring the existing
  `lastPlayedTrack`/`setLastPlayedTrack` pair.
- Setting and reading round-trip correctly; different playlist slugs are tracked independently.
- Backward-compatible: an existing `player-state.json` written before this field existed decodes
  fine, with the new field defaulting to empty (same pattern already used for
  `CachedTrack.normalizationGain`/`BGMTrack` field additions elsewhere in this codebase).

## Notes

App-generated data only (a float derived from `AVPlayer`'s own playback position) — no
external/untrusted input, same rationale as `player-state-001`.

Per SPEC.md's "Local state (per playlist)": this is a single saved position per playlist slot,
tied to whichever track is currently the "last played" one for that slot — switching to a
different track discards the old track's saved position. It is the caller's responsibility (not
this storage layer's) to only write a position that actually corresponds to the track currently
recorded in `lastPlayedTrackByPlaylist` for that slug, so the two stay consistent.
