---
id: bgm-001
title: BGM track cache schema & storage
status: open
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
