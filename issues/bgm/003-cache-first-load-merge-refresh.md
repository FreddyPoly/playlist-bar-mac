---
id: bgm-003
title: Cache-first pooled load with listen-count-preserving 24h refresh
status: done
security: false
owner: agent
depends_on: [bgm-002]
spec_ref: "SPEC.md#bgm-channel-playback"
---

## Description

Load the BGM pool cache-first (instant from disk when present), refreshing in the background when
stale (>24h, same threshold as `playlist-data-003`) by rescanning every configured channel
(`bgm-002`) and merging results into the existing pool (`bgm-001`) rather than replacing it.

## Acceptance criteria

- On first use with no existing BGM cache, performs a full scan of every configured channel
  (currently one) and populates the pool.
- On subsequent use with a fresh (<24h) cache, returns instantly from disk with no scan.
- On subsequent use with a stale (>24h) cache, returns the existing cached pool immediately while
  a rescan runs in the background; once the rescan completes, the pool is updated in place.
- The rescan **merges by video id** rather than replacing wholesale: a video still eligible after
  rescanning keeps its existing local listen count (and normalization gain, if tracked in the same
  record); a video no longer present/eligible (deleted, went members-only, channel removed it) is
  dropped from the pool; a newly-eligible video is added starting at 0 listens.
- A failed rescan (yt-dlp error, network failure) leaves the existing cached pool untouched — same
  "don't let a broken refresh take away a working cache" behavior as `playlist-data-003`.

## Notes

This is the issue that actually exercises `bgm-001`'s merge behavior — `bgm-001` only needs to
provide the merge primitive; this issue is responsible for calling it at the right time (on a
stale-cache background refresh) instead of a full replace.

This intentionally diverges from `playlist-data-003`'s behavior, which fully replaces its cached
track list on every rescan (and, as a side effect, silently drops `normalizationGain` until it's
re-measured). For BGM, that would silently reset every video's listen count every 24 hours,
defeating the fewest-listens selection this feature exists for — so the merge requirement here is
load-bearing, not a nice-to-have.

## Implemented (2026-08-10)

`Sources/PlaylistBar/BGMChannels.swift` — `BGMChannels.all: [String]`, the configured channel
URL list (currently the one channel), mirroring `FixedPlaylists.all`'s hardcoded-list convention.
Needed a home and this issue (the multi-channel orchestrator) is the natural consumer of it,
rather than `bgm-002` (which only ever scans one channel URL at a time and doesn't need to know
the full configured list).

`Sources/PlaylistBar/BGMLoader.swift` — `BGMLoader`, a structural mirror of `PlaylistLoader`
(`@MainActor` `ObservableObject`, `tracks`/`isLoading`/`lastScanErrorMessage`/`onTracksUpdated`,
same cancel-in-flight-then-restart `activeTask` pattern): `load()` returns instantly from
`BGMCacheStore` when a cache exists, kicking off a background refresh only if stale; with no cache
at all, blocks on a full scan. The refresh (`rescanAndMerge`) scans every `BGMChannels.all` entry
via `BGMChannelScanner`, pools+dedupes results across channels by video id (first channel to
report a given id wins), merges the pooled result against whatever's currently on disk via
`BGMCacheStore.merge` (not the in-memory `tracks`, to avoid merging against a possibly-stale
snapshot), and persists it. A scan failure (any channel) leaves the existing cache/displayed pool
untouched and surfaces `lastScanErrorMessage`, same "a broken refresh shouldn't take away a
working cache" rule as `PlaylistLoader.rescanAndStore`.

**Verification**: `PlaylistLoader`'s own convention (and this whole package being an
`executableTarget`, not a library) means there's no way to import the real module into a
standalone script — so this was verified via a script containing the *actual* `BGMLoader` logic
copied verbatim, with only the channel-scan call replaced by an injectable closure (so the
decision logic — cache-first, staleness, merge, failure-handling — could be exercised
deterministically without hitting the real network on every run; the real network path itself was
already verified independently in `bgm-002`). Covered: a cold load calls the scan exactly once and
persists the result; a fresh (<24h) cache serves cached data (including a manually-bumped listen
count) with **no** scan call at all; a stale (>24h) cache triggers exactly one scan and the merged
result preserves the existing video's listen count while adding a newly-eligible video at 0; a
failed scan on a stale cache leaves the existing cached tracks, on-disk file, and (surfaced)
listen count completely untouched, with an error message set. All passed. `swift build` succeeds
with no warnings.

**Review**: manual pass in place of `/code-review` (agent-invocation disabled — see `bgm-002`'s
Notes for the full explanation). `security: false` — no new subprocess/parsing surface beyond
what `bgm-002` already introduced and reviewed; this issue is pure orchestration over already-
reviewed pieces. No findings.
