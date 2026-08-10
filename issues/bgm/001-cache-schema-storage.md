---
id: bgm-001
title: BGM track cache schema & storage
status: done
security: false
owner: agent
depends_on: []
spec_ref: "SPEC.md#bgm-channel-playback"
---

## Description

Define the on-disk model and storage helpers for BGM's pooled channel tracks — distinct from
`playlist-data`'s per-playlist cache, since a BGM track additionally carries a **local listen
count** that must survive a rescan (see `bgm-003`), and the pool is sourced from one or more
channels (currently one, structured to allow more later — see SPEC.md's "BGM channel playback").

## Acceptance criteria

- A BGM track record captures at least: video id, title, duration (seconds, used for the
  15-minute filter and the listen-count threshold), and a local listen count (starts at 0).
- Storage supports looking up and incrementing one track's listen count by video id without
  requiring a full rewrite of unrelated tracks.
- Storage supports merging a freshly-scanned set of tracks into the existing pool by video id —
  a track still present after a rescan keeps its existing listen count (and cached normalization
  gain, if that's tracked here too); a track no longer present in any configured channel is
  dropped; a genuinely new track starts at 0.
- Persisted as local JSON under `~/Library/Application Support/PlaylistBar/`, consistent with
  the rest of this app's local state.
- Schema is structured around a **list of channels**, even though only one is configured today —
  don't hardcode an assumption of exactly one channel into the storage shape.

## Notes

This is intentionally storage/schema only — the channel scan itself is `bgm-002`, and the
staleness/refresh policy that calls the merge behavior described here is `bgm-003`.

Per SPEC.md, this cache's merge-on-rescan behavior is a deliberate deviation from
`playlist-data`'s cache (which fully replaces its track list, and consequently silently drops
`normalizationGain`, on every 24h rescan) — for BGM, losing listen counts on every rescan would
defeat the feature, so merge-by-video-id is a hard requirement here, not an optimization.

No untrusted input at this layer (it stores/merges data the app itself already validated) — the
scan in `bgm-002` is where third-party (YouTube) data first enters, so that's the security-flagged
issue, not this one.

## Implemented (2026-08-10)

`Sources/PlaylistBar/BGMCache.swift`: `BGMTrack` (video id, title, duration, `listenCount` default
0, `normalizationGain: Double? = nil`), `BGMPoolCache` (`tracks`/`lastScannedAt`, same immutable
`let`-field shape as `PlaylistCache`, plus `isStale` at the same 24h threshold), and
`BGMCacheStore` with `load`/`save`/`merge(freshlyScanned:into:)`/`incrementListenCount(forVideoID:)`
/`setNormalizationGain(_:forVideoID:)`, persisted as `bgm-pool.json` under
`~/Library/Application Support/PlaylistBar/`.

`normalizationGain` was added to `BGMTrack` even though the acceptance criteria only required it
"if that's tracked here too" — per SPEC.md, per-track loudness normalization is meant to apply to
BGM videos exactly as it does regular tracks, and there's no other cache file for BGM tracks to
live in, so this avoids a schema migration once `bgm-006` wires playback in.

The pool schema deliberately carries no per-track "which channel did this come from" field — the
pool is one shared selection space across all configured channels (per the interview's decision
to pool rather than have one picker entry per channel), so channel origin isn't needed by
anything this cache does. One shared `lastScannedAt` covers the whole pool rather than per-channel
timestamps, noted in the code as a simplification worth revisiting only if per-channel staleness
ever actually matters.

**Convention fix during self-review**: initial version made `BGMPoolCache.tracks`/`lastScannedAt`
`var` and mutated in place inside `incrementListenCount`/`setNormalizationGain`. Caught that this
diverges from `PlaylistCacheStore.setNormalizationGain`'s established pattern (immutable `let`
struct fields, copy-mutate-reconstruct-save) and fixed it to match before marking this done.

**Verification**: `/code-review` can't be invoked by the agent directly (`disable-model-invocation`
— reserved for explicit user invocation), so this was a manual self-review pass instead, which is
what caught the convention drift above. Logic verified via a standalone script (this project has
no test framework — see `CLAUDE.md`'s convention) covering: missing-cache load, save/load
round-trip, freshness, increment-by-id (including a no-op for an unknown id), gain update, and the
full merge matrix (existing track keeps count+gain even when the fresh scan has neither; a
disappeared track is dropped; a new track starts at 0/nil; fresh metadata like a retitle still
applies). All checks passed. `swift build` succeeds with no warnings.
