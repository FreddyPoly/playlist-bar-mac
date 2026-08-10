---
id: bgm-008
title: Reset restarts the current BGM video instead of jumping
status: open
security: false
owner: agent
depends_on: [bgm-006]
spec_ref: "SPEC.md#behavior-rules"
---

## Description

For the 4 fixed playlists, Reset jumps to track 1 (`playback-controller-003`). BGM has no "track
1," so Reset instead restarts the **current** video from 0:00, leaving the selection and session
history untouched.

## Acceptance criteria

- Pressing Reset while in BGM mode restarts playback of whichever video is currently selected,
  from 0:00 — it does not pick a new video (that's what Next is for) and does not change the
  persisted last-played video (it's already the current one).
- Reset does not affect or truncate the Previous session history (`bgm-007`).

## Notes

Small, deliberate behavioral divergence from `playback-controller-003` — confirm the Reset button
in the UI (`menu-bar-ui-002`) doesn't need any visible change, since it's the controller's
handling of the Reset action that differs by mode, not the button itself.
