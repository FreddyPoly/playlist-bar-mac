---
id: volume-control-004
title: Persist measured per-track gain in the playlist cache
status: done
security: false
owner: agent
depends_on: [volume-control-003]
spec_ref: "SPEC.md#volume--loudness-normalization"
---

## Description

Extend the per-track cache entry (`CachedTrack` / `PlaylistCache`, see `playlist-data-001`) with
an optional measured normalization gain, so a track's loudness is only ever analyzed once and
survives relaunch.

## Acceptance criteria

- `CachedTrack` gains an optional gain field (e.g. `normalizationGain: Double?`), absent/`nil`
  for any track never analyzed — a valid, expected state, not an error.
- `PlaylistCacheStore`'s existing load/save round-trips this field like any other cached data.
- Once a track has a cached gain, it is never re-measured — looking it up is a plain cache read,
  no `ffmpeg` call.
- Setting a track's gain (after `volume-control-003` measures it) updates just that track's cache
  entry and persists it, without needing a full playlist re-scan.
- Existing cache files written before this change (missing the new field entirely) load without
  error — the field is simply absent/`nil` for every track until each is analyzed.

## Notes

Added 2026-08-09. Backward-compatible schema addition — no migration needed, matches how other
optional additions to this JSON cache have presumably been handled before.

**Implemented 2026-08-09**: `CachedTrack` gained `var normalizationGain: Double? = nil` (must be
`var`, not `let` — a `let` stored property with an initial value is a compiler-flagged
non-decodable constant in Swift, so it would've silently always decoded as `nil` regardless of
what was on disk). `PlaylistCacheStore.setNormalizationGain(_:forVideoID:playlistSlug:)` updates
one track in place and persists via the existing `save`. Verified via a standalone script
(mirroring this project's no-test-suite convention): old-format JSON missing the field decodes to
`nil`, round-trip with a gain set preserves it, round-trip with gain still `nil` stays `nil`.
Reviewed manually in place of `/code-review` (no git repo yet); no issues found.
