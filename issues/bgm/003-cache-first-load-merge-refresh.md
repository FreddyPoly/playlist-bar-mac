---
id: bgm-003
title: Cache-first pooled load with listen-count-preserving 24h refresh
status: open
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
