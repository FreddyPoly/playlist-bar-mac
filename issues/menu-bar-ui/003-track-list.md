---
id: menu-bar-ui-003
title: Track list (previous 5 / current / next 5)
status: done
security: false
owner: agent
depends_on: [playback-controller-005, playlist-data-003]
spec_ref: "SPEC.md#ui-menu-bar-dropdown"
---

## Description

Display the current track plus up to 5 previous and up to 5 next tracks (by playlist index, from
the cached track list), each clickable to jump/play per playback-controller-005. Near the start
or end of the playlist, show fewer neighbors rather than wrapping the *displayed list* around
(wrap-around only applies to Previous/Next button behavior, per SPEC.md, not to what's shown in
this list).

## Acceptance criteria

- The list shows the correct neighboring tracks by index for the active playlist and updates live
  as the current track changes.
- Clicking any entry plays it immediately (playback-controller-005).
- Near playlist start/end, the list simply shows fewer than 5 neighbors on that side rather than
  wrapping to the other end of the playlist.

## Notes

Track titles are rendered as plain text (SwiftUI `Text`), never interpreted as markup — no
injection surface from playlist content per SPEC.md's Security section.

Added a `displayedTracks` computed property to `ContentView`: `lower = max(0, current - 5)`,
`upper = min(tracks.count - 1, current + 5)`, clamped independently at each end so a playlist
shorter than the window (or a current index near either edge) simply shows fewer neighbors on
that side rather than wrapping or crashing on an out-of-range slice. Each row is a `Button`
calling `controller.selectTrack(at:)` (playback-controller-005), with the current track
visually distinguished (accent color + semibold). Wrapped in a bounded-height `ScrollView` so a
long list doesn't grow the dropdown unbounded.

Verified the windowing math directly (pure function of current index + track count, extracted
into a standalone check) across all the boundary cases that matter: the middle of a playlist
(full 11-item window), right at index 0 and near it (no negative indices, just fewer previous
entries), right at the last index and near it (no over-the-end indices, just fewer next entries),
and a playlist smaller than the window itself (shows every track, no crash). Confirmed the app
still builds and launches cleanly with this view added.

Same visual-verification limitation as menu-bar-ui-001/002 — couldn't screenshot the actual
rendered list or click-test a row in this environment; the underlying selection logic
(`selectTrack`) was independently verified in playback-controller-005.

## QC feedback (2026-08-09)

**Scenario tested** (during playlist-data QC, feature: app-shell/playlist-data pass): fresh
launch (no prior cache), open dropdown, select "Jazz" from the playlist picker for the first
time.

**Expected** (per this issue's acceptance criteria): the track list (previous 5 / current / next
5) populates and shows the current track highlighted, live as soon as loading/resolution
completes.

**Actual**: after ~10s (scan + stream resolution), playback started (audio audible, transport
buttons became enabled — confirming `controller.currentIndex`/`controller.tracks` were genuinely
populated: `~/Library/Application Support/PlaylistBar/jazz.json` on disk has the correct 178-track
list, and `player-state.json` correctly recorded the resumed track), but the dropdown's track
list stayed completely empty — no rows, not even the current track. Closing and reopening the
dropdown did **not** fix it; it stayed empty.

Since the underlying state (`controller.currentIndex`, `controller.tracks`) is confirmed correct
via the cache/state files, this points to a rendering/reactivity bug in `ContentView`'s
`displayedTracks`/`ScrollView` — worth checking whether `MenuBarExtra(.window style)`'s content is
being retained/reused in a way that isn't picking up `@ObservedObject` updates, and specifically
whether a *freshly opened* dropdown (not just a live-updating already-open one) correctly computes
`displayedTracks` from current controller state at open time.

Related: the menu bar label (menu-bar-ui-004) exhibited the same symptom simultaneously (blank
title, not updating), suggesting a shared root cause rather than two independent bugs — worth
investigating together.

## Fix (2026-08-09)

Root cause confirmed via instrumented debug build: `ContentView.body` (and the `displayedTracks`
computed property feeding it) *was* being re-evaluated correctly with the right data
(`currentIndex`/`tracks` were never wrong — verified via temporary print statements showing 178
tracks and the correct current index). Not a reactivity bug at all. The actual bug was pure
layout: the `ScrollView` had only `.frame(maxHeight: 220)`, no minimum/fixed height. Inside
`MenuBarExtra`'s auto-sizing `.window`-style content, a `ScrollView` with no minimum height
resolves its ideal height to effectively zero even with real rows inside it — confirmed visually
via a user-supplied screenshot showing the space between the two `Divider()`s compressed to almost
nothing, rather than genuinely empty.

Fix: `.frame(minHeight: 130, maxHeight: 220)` — reserves enough height to show ~4 rows before
scrolling kicks in (tuned live with the user against the real running app), while still capping
the list at a reasonable max for long playlists.

Re-verified end-to-end with the user against the real packaged app: fresh launch restoring a
previous Jazz session, dropdown opened — track list now populates immediately, current track
("ALIBI") highlighted in accent color, ~4 rows visible without scrolling. All three acceptance
criteria hold; the click-to-play and near-edge windowing behavior were unaffected by this change
(no logic touched, only the `ScrollView`'s frame).
