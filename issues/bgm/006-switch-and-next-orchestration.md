---
id: bgm-006
title: BGM switch-to + Next selection orchestration
status: open
security: false
owner: agent
depends_on: [bgm-003, bgm-004, bgm-005, playback-controller-001]
spec_ref: "SPEC.md#bgm-channel-playback"
---

## Description

Wire BGM into the playback controller as a selectable entry: switching to BGM loads the pooled
channel cache (`bgm-003`) and starts playing a selected video; pressing Next (or auto-advance on
natural end) picks a new video via `bgm-004`'s selection algorithm, plays it, appends it to the
session history (see `bgm-007`), and persists it as the resumable position.

## Acceptance criteria

- Selecting "BGM" from the playlist picker loads the pooled cache (instant if cached, per
  `bgm-003`) and starts playback of a video — the persisted last-played BGM video if one exists
  (see `bgm-009`), otherwise a fresh selection via `bgm-004`.
- Pressing Next, or a BGM video finishing naturally, picks a new video via `bgm-004` (excluding the
  video that was just playing), plays it, and records it as the new resumable position — same
  "persist on every track change" behavior the 4 fixed playlists already have
  (`player-state-001`), reusing that same per-slug storage with a `"bgm"` slug rather than
  building a parallel mechanism.
- Unavailable-video handling (deleted/private/region-locked) still applies the same way it does
  for the 4 fixed playlists — a video that fails to resolve is skipped in favor of another
  selection, not treated as a hard failure.
- Loudness normalization and master volume trim apply to BGM playback exactly as they do to
  regular tracks (no special-casing needed if BGM videos flow through the same playback path as
  regular tracks).
- Only one thing plays at a time — switching to or within BGM stops whatever was previously
  playing, same rule as the 4 fixed playlists.

## Notes

This issue deliberately covers only **switch-to** and **Next/auto-advance**. Previous
(`bgm-007`) and Reset (`bgm-008`) are separate issues since their semantics diverge further from
each other and from Next — keep this issue's scope to what's shared between initial selection and
forward progression.

BGM has no fixed playlist index, so this can't reuse `playback-controller-001`'s exact
index-stepping machinery — but it can and should reuse the same generation-guard pattern (against
overlapping/stale async calls) and the same persistence/Now-Playing-info plumbing that
`playback-controller-001` already established, rather than duplicating it.
