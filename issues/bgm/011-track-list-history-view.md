---
id: bgm-011
title: BGM track list — history + current, no "next" slot
status: open
security: false
owner: agent
depends_on: [bgm-005, bgm-006, bgm-007]
spec_ref: "SPEC.md#ui-menu-bar-dropdown"
---

## Description

Replace the regular "5 previous / current / 5 next by index" track list (`menu-bar-ui-003`) with a
BGM-specific variant while BGM is the active selection: up to 5 previously-played videos this
session (`bgm-007`'s history, click any to jump back to it) plus the current track highlighted,
with each visible entry's local listen count shown next to its title. No "next" slot, since the
next pick genuinely isn't determined ahead of time.

## Acceptance criteria

- While BGM is active, the track list shows up to 5 entries from the session's Previous history
  (most-recently-played closest to the current entry) plus the current track, and nothing beyond
  that (no "next" entries, no full-catalog browsing).
- Each shown entry (history + current) displays its local listen count next to its title.
- Clicking a history entry jumps to it, same interaction as `bgm-007`'s Previous-to-a-specific-
  point behavior.
- Switching away from BGM to a fixed playlist restores the regular `menu-bar-ui-003` list
  behavior (and vice versa) — the two list modes don't leak into each other.

## Notes

This was an explicit design change made after discussion during the interview: an earlier version
of this spec considered showing the full pooled catalog (all ~106 eligible videos), but that was
rejected as unhelpful for actually picking a track, and "5 next" was rejected as meaningless when
the next pick isn't decided yet. Don't reintroduce either without checking back — this
history-only shape was the deliberate resolution.
