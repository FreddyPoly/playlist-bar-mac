---
id: menu-bar-ui-001
title: Playlist selector dropdown
status: done
security: false
owner: agent
depends_on: [playback-controller-001]
spec_ref: "SPEC.md#ui-menu-bar-dropdown"
---

## Description

Add a control in the menu bar dropdown listing the 4 fixed playlists by name (Rock3,
Drum'N'Bass, Tranquille, Jazz); selecting one triggers playback-controller-001's playlist switch.

## Acceptance criteria

- All 4 playlists are selectable by name.
- Selecting one switches to it and starts playback per playback-controller-001.
- The selector reflects the currently active playlist.

## Notes

The 4 playlists and their URLs are fixed per SPEC.md — no UI to add/remove/edit playlists.

Added a `Picker` to `ContentView` (now backed by `@StateObject private var controller =
PlaybackController()`), listing all 4 `FixedPlaylists`. Deliberately **not** a direct
`$controller.currentPlaylist` binding — `currentPlaylist` is `private(set)` on purpose (selecting
a playlist has to go through `switchTo(playlist:)`'s real side effects: stopping current
playback, loading, resolving, persisting — not just storing a value) — so the Picker uses a
manually-constructed `Binding` whose setter calls `Task { await controller.switchTo(...) }`. Added
`Hashable` conformance to `Playlist` (needed for `Picker` tag matching); `Equatable`/`Identifiable`
were already there from playback-controller-001.

**Verification limitation:** the app builds and runs without crashing with this change
(`swift build` clean, process stays alive, no errors in output). I attempted to screenshot the
running app to visually confirm the picker renders and lists all 4 playlists correctly, but
`screencapture` in this environment captures only this coding-session window — the actual macOS
menu bar strip at the top of the captured screenshot is fully black, meaning this environment's
screen capture doesn't show the real system menu bar (likely a virtual/remote display setup).
Synthetic clicking via System Events is also unavailable (no Accessibility permission granted to
this session, per app-shell-001's earlier note). The underlying `switchTo` logic this Picker calls
into was already extensively verified directly in playback-controller-001's tests, so the risk
surface here is narrow (a fairly standard SwiftUI `Picker` + `Binding`), but the actual rendered
UI has not been visually confirmed — please check it yourself with `swift run` when you get a
chance.
