---
id: playlist-data-001
title: Cache schema & storage helpers
status: done
security: false
owner: agent
depends_on: []
spec_ref: "SPEC.md#playlist-data--caching"
---

## Description

Define Swift models for a cached playlist entry (video id, title) and a per-playlist cache file
(ordered track list + last-scanned timestamp). Implement read/write helpers targeting
`~/Library/Application Support/PlaylistBar/<playlist-slug>.json`, creating the directory if it
doesn't exist.

## Acceptance criteria

- Models are `Codable`.
- Writing a cache then reading it back round-trips exactly (same order, same fields).
- The `~/Library/Application Support/PlaylistBar/` directory is created automatically if missing.
- One cache file per playlist (4 fixed playlists → 4 possible cache files), keyed by a stable
  slug (e.g. derived from playlist name, not the YouTube playlist ID, for readability — either is
  fine as long as it's stable across launches).

## Notes

This stores only app-generated/already-parsed data (no raw external input handled directly by
this issue) — the actual yt-dlp scan and parsing is playlist-data-002.

Implemented in `Sources/PlaylistBar/PlaylistCache.swift`: `CachedTrack` (video id + title),
`PlaylistCache` (ordered tracks + `lastScannedAt`, with an `isStale` computed property using a
24h threshold — matches SPEC.md's refresh policy, ready for playlist-data-003 to consume
directly), and `PlaylistCacheStore` with `load(playlistSlug:)` / `save(_:playlistSlug:)`, keyed by
a playlist slug (e.g. `"rock3"`) rather than the raw YouTube playlist ID, for readable filenames.

Verified with a real round-trip test (write → read back) covering: exact equality of loaded vs.
saved tracks (including titles with emoji/quotes to confirm JSON encoding handles them), a
missing-playlist load correctly returning `nil`, auto-creation of
`~/Library/Application Support/PlaylistBar/`, and `isStale` correctly false right after saving
and true after backdating `lastScannedAt` by 25 hours. Test artifacts were cleaned up afterward.
