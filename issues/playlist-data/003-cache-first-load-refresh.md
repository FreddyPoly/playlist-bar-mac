---
id: playlist-data-003
title: Cache-first load with 24h staleness refresh
status: done
security: false
owner: agent
depends_on: [playlist-data-002]
spec_ref: "SPEC.md#playlist-data--caching"
---

## Description

Implement the "load playlist" entry point used by the rest of the app: return the cached track
list immediately if present, and independently trigger a background full re-scan
(playlist-data-002) if the cache is missing or its timestamp is more than 24 hours old, replacing
the cache file once the re-scan completes.

## Acceptance criteria

- First-ever call for a playlist with no existing cache performs a full scan (exposing a loading
  state to callers) and populates the cache.
- A call within 24h of the last scan returns cached data immediately with no scan triggered.
- A call after the cache is >24h old returns the existing cached data immediately while a refresh
  runs in the background; once the refresh completes, the in-memory/displayed track list and the
  cache file are updated to match.
- A failed background refresh (e.g. network error) leaves the existing cache untouched and usable
  — it does not wipe out a working cache.

## Notes

This is orchestration only; the actual scanning and untrusted-data handling is already covered
(and flagged security-sensitive) in playlist-data-002.

Implemented as `PlaylistLoader`, a `@MainActor` `ObservableObject` in
`Sources/PlaylistBar/PlaylistLoader.swift`, publishing `tracks: [CachedTrack]` and `isLoading:
Bool` so SwiftUI views can observe both the cache-first result and background-refresh updates
directly. `load(playlistSlug:playlistURL:)` cancels any in-flight refresh for a previous playlist
before proceeding (relevant once playback-controller-001 calls this repeatedly across playlist
switches). The actual yt-dlp scan runs via `Task.detached` off the main actor, since
`PlaylistScanner.scan` blocks synchronously on the subprocess.

Verified all four acceptance-criteria scenarios end-to-end against the real Jazz playlist (via a
standalone script exercising the actual production code):
- No cache → full scan (178 tracks in ~2.1s), `isLoading` correctly false once done.
- Fresh (<24h) cache → returned in ~0.0002s, confirming no scan was triggered.
- Stale (>24h, backdated) cache → a fake 1-track cache returned immediately (~0.00004s), then
  after a few seconds both the published `tracks` and the on-disk cache updated to the real
  178-track scan result.
- Stale cache + a broken playlist URL → the fake cache's track was returned immediately and
  **remained unchanged**, both in-memory and on disk, after the background refresh failed —
  confirming a failed refresh doesn't destroy a working cache.

Test artifacts (including the real `jazz` cache written during testing) were cleaned up from
`~/Library/Application Support/PlaylistBar/` afterward.

**Security review:** not flagged `security: true` — this issue only orchestrates already-covered
pieces (cache I/O from playlist-data-001, scanning from playlist-data-002) and introduces no new
untrusted-input handling.
