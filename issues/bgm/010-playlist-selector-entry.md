---
id: bgm-010
title: "BGM" entry in the playlist selector dropdown
status: done
security: false
owner: agent
depends_on: [bgm-006, menu-bar-ui-001]
spec_ref: "SPEC.md#ui-menu-bar-dropdown"
---

## Description

Add "BGM" as a 5th entry in the existing playlist selector dropdown (`menu-bar-ui-001`), alongside
the 4 fixed playlists, so it can be selected the same way.

## Acceptance criteria

- The playlist picker lists "BGM" alongside Rock3 / Drum'N'Bass / Tranquille / Jazz.
- Selecting "BGM" triggers `bgm-006`'s switch-to behavior (loads and plays), the same way
  selecting a fixed playlist triggers `playback-controller-001`'s.
- Selecting a fixed playlist while BGM is active (or vice versa) stops whatever was playing first,
  same single-thing-plays-at-a-time rule as switching between any two of the 4 fixed playlists.

## Notes

Purely the picker/UI wiring — the actual load/selection behavior it triggers belongs to `bgm-006`,
not this issue.

## Implemented (2026-08-10)

Added `PlaybackController.bgmPlaylist: Playlist` — a single shared static constant for the
synthetic BGM `Playlist` value (refactored `switchToBGM()`/`restoreBGMSession()`, which previously
each constructed their own literal `Playlist(slug: "bgm", name: "BGM", url: "")`, to use this one
constant instead). This mattered specifically for the picker: `Playlist`'s `Equatable`/`Hashable`
conformance is field-based (all of `slug`/`name`/`url`, not just `id`), so two independently-
constructed "equivalent" literals would only accidentally compare equal today — any future edit to
one but not the other would silently break the picker's selection-highlighting without any
compile error. A single shared constant makes that impossible by construction.

`ContentView.swift`: added a row (`Text(PlaybackController.bgmPlaylist.name).tag(Optional(
PlaybackController.bgmPlaylist))`) to the existing `Picker`, after the 4 fixed playlists.
`playlistSelection`'s `set` closure now branches: selecting the BGM row calls
`controller.switchToBGM()`, selecting one of the 4 fixed playlists calls the existing
`controller.switchTo(playlist:)` unchanged.

**Verification**: `swift build` succeeds with no warnings. Ran the real app (`swift run`) and
confirmed it launches and stays running (no crash) with these changes — full interactive/visual
verification of the picker (actually clicking "BGM," confirming it highlights correctly, confirming
switching between BGM and a fixed playlist behaves as expected) needs the user, consistent with
this project's existing limitation (no macOS UI automation tool available in this environment —
see `CLAUDE.md`'s "Known gaps" section). Not silently claimed as fully verified.

**Review**: manual pass in place of `/code-review` (see `bgm-002`'s Notes). `security: false` —
pure UI wiring plus a refactor to a shared constant (no behavior change to what was already
reviewed in `bgm-006`/`bgm-009`). No findings.
