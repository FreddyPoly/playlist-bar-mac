---
id: bgm-011
title: BGM track list — history + current, no "next" slot
status: done
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

## Implemented (2026-08-10)

Added `PlaybackController.bgmCurrentHistoryIndex: Int?` — `bgmHistoryPosition` if set (mid
walk-back) else the live edge (`bgmHistory.count - 1`), `nil` only when there's no history yet.
Exposed rather than the private `bgmHistoryPosition` itself, so the view layer doesn't need to
know that implementation detail. Not `@Published` itself, but every call that changes
`bgmHistoryPosition` also changes `tracks`/`currentIndex` (both `@Published`) in the same method
(`bgm-007`), so SwiftUI still re-renders correctly.

`ContentView.swift`: the track-list `ScrollView` now branches on `controller.isBGMActive`. The BGM
branch renders `displayedBGMHistory` (a new computed property: `bgmHistory[max(0, current-5)...
current]`, i.e. up to 5 previous entries plus whichever one `bgmCurrentHistoryIndex` points to —
no window past `current`, since there's no "next" concept) — each row shows the title, the
highlighted-if-current styling (same accent-color/semibold convention as the fixed-playlist list),
and the track's local listen count in secondary/caption text on the trailing edge. Clicking a row
calls `controller.selectBGMHistoryEntry(at:)` (`bgm-007`). The non-BGM branch is the pre-existing
`displayedTracks` list, completely unchanged.

**Known, disclosed simplification**: each row's listen count comes from the `BGMTrack` snapshot
stored in `bgmHistory` at selection time, not a live re-read of the pool — so the *currently
playing* track's shown count won't visibly tick up in real time as `bgm-005`'s threshold is
crossed mid-play; it reflects "how many times heard before this play" rather than a live counter.
Judged acceptable (the count is still accurate and meaningful, just not live-updating for the one
row where it's actively changing) rather than adding a reactive re-fetch from `bgmLoader.tracks`
for a minor display polish detail.

**Verification**: `displayedBGMHistory`'s windowing math was verified via a standalone script
across boundary cases — empty history, a single entry, fewer than 6 entries (shows all of them,
no crash on the `(lower...current)` range), more than 6 entries at the live edge (shows exactly
the last 6, correctly ending on the current one), and — the case most likely to have a subtle bug
— a *mid walk-back* position (not the live edge), confirming the window centers on the walked-back
position and never shows anything "after" it. All passed. `swift build` succeeds with no
warnings. Ran the real app (`swift run`) and confirmed it launches and stays running with no
crash. Full interactive/visual verification (actually selecting BGM, confirming the history list
renders and updates correctly as videos play/Next/Previous are used) needs the user, consistent
with this project's existing limitation — not silently claimed as fully verified.

**Review**: manual pass in place of `/code-review` (see `bgm-002`'s Notes). `security: false` —
plain SwiftUI rendering of already-local data (track titles, same safe-rendering convention this
app already established for CJK/ampersand titles — see `menu-bar-ui-003`'s Notes), no new
subprocess/parsing surface. No findings.

## bgm feature complete

This was the last open `bgm-*` issue — all 11 are now `done`. The `bgm` feature is ready for QC
(`issues/FEATURES.md` updated to `ready-for-qc`).
