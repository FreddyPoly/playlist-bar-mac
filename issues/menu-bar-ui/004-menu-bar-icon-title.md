---
id: menu-bar-ui-004
title: Menu bar icon + current track title
status: done
security: false
owner: agent
depends_on: [playback-controller-001]
spec_ref: "SPEC.md#ui-menu-bar-dropdown"
---

## Description

Menu bar item shows a small icon plus the current track's title (truncated as needed) next to
it, updating as the track changes.

## Acceptance criteria

- Menu bar text reflects the currently playing/selected track title.
- Long titles are truncated (e.g. with an ellipsis) rather than breaking the menu bar layout.
- An icon is shown alongside the title text.

## Notes

**Icon confirmed final (2026-08-10):** SPEC.md specifies "icon + scrolling track title" but
didn't pin down the exact icon design, so this was built with the SF Symbol `music.note` as a
placeholder pending a preference. Frederic confirmed the default `music.note` icon is fine as-is
— no swap needed, so this is no longer an open placeholder (`owner` updated from `placeholder` to
`agent` accordingly). Static truncated title, not actually scrolling — treated the scrolling
behavior as a nice-to-have per the original issue's own note, since a static truncated title
satisfies the spec's core requirement without the added complexity of a marquee animation.

**Required refactor:** this issue needed the menu bar label and the dropdown to observe the *same*
`PlaybackController` instance — otherwise switching playlists in the dropdown would never show up
in the menu bar title (two separate controllers = two separate states). Moved
`@StateObject private var controller` from `ContentView` up to `PlaylistBarApp` (owned at the App
level) and changed `ContentView` to take it as an injected `@ObservedObject var controller:
PlaybackController` instead. Also switched from `MenuBarExtra(_:systemImage:content:)` to the
`MenuBarExtra(content:label:)` form so the label can be computed dynamically from
`controller.currentIndex`/`tracks` rather than a fixed string.

Verified the truncation math directly (40-char cutoff + ellipsis): no active track → "Playlist
Bar"; a short title passes through unchanged; a title over 40 characters is correctly cut to 40
chars + "…". Confirmed the app still builds and launches cleanly after the controller-ownership
refactor.

Same visual-verification limitation as the other menu-bar-ui issues — couldn't screenshot the
actual menu bar icon/text in this environment. Please check visually that the icon and title
render as expected (and that the title genuinely updates as tracks change) when you get a chance.

## QC feedback (2026-08-09)

**Scenario tested** (during playlist-data QC): fresh launch (no prior cache), selected "Jazz"
from the playlist picker for the first time.

**Expected**: menu bar label updates from "Playlist Bar" to the resolved current track's
(truncated) title once playback starts.

**Actual**: label stayed blank/unchanged — no track title ever appeared next to the icon, even
though playback genuinely started (audio audible, transport controls enabled, and
`player-state.json`/`jazz.json` on disk confirm `controller.currentIndex`/`tracks` were correctly
populated). This is the exact "please check visually" caveat this issue's own notes called out —
turns out it doesn't work.

Likely root cause: `menuBarTitle` is a computed property read inside the `label:` closure of
`MenuBarExtra(content:label:)` in `PlaylistBarApp.swift` — this is a known-flaky pattern in
SwiftUI/`MenuBarExtra` where the label closure doesn't reliably re-evaluate on `@Published`
changes to a `@StateObject` owned by the `App`. Worth checking whether the label actually needs an
explicit `.id(...)` tied to `controller.currentIndex`, or whether `MenuBarExtra`'s label needs to
observe the object more directly (e.g. via `@ObservedObject` in a small dedicated label view)
rather than relying on `App.body` invalidation to propagate into the label closure.

Same symptom appeared simultaneously in the dropdown's track list (menu-bar-ui-003) — investigate
together, likely a shared root cause in how `PlaybackController`'s published state propagates (or
fails to) into `MenuBarExtra`'s label/content closures specifically.

## Fix (2026-08-09)

Root cause was **not** a reactivity bug — instrumented debug prints confirmed `menuBarTitle` was
being recomputed correctly (right `currentIndex`/`tracks.count`, right resulting string) every
time the underlying state changed. The actual bug: `Label(menuBarTitle, systemImage: "music.note")`
was being used as `MenuBarExtra`'s label, and a `MenuBarExtra` status item doesn't reliably render
`Label`'s title text next to its icon — it silently collapses to icon-only, in every state,
confirmed via a user-supplied screenshot showing only the music note icon and no text at all next
to it (not even the "Playlist Bar" fallback).

Fix: replaced the `Label` with an explicit `HStack { Image(systemName:); Text(menuBarTitle) }`,
the standard workaround for this known `MenuBarExtra` limitation. Re-verified with the user
against the real packaged app: menu bar now correctly shows "♪ ALIBI" reflecting the actual
current track, updating as expected. This was investigated together with menu-bar-ui-003 (same
QC session, simultaneous symptom) — turned out to be two unrelated bugs (a layout sizing bug there,
a label-rendering limitation here) that happened to surface at the same time, not a shared root
cause as originally suspected.

Truncation and icon-presence acceptance criteria were unaffected by this change (same
`menuBarTitle` computation, same SF Symbol) and were already verified in the original pass.
