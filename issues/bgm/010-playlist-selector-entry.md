---
id: bgm-010
title: "BGM" entry in the playlist selector dropdown
status: open
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
