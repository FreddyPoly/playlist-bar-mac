---
id: bgm-007
title: Session-only Previous history navigation
status: open
security: false
owner: agent
depends_on: [bgm-006]
spec_ref: "SPEC.md#behavior-rules"
---

## Description

Implement Previous for BGM as a walk backward through the videos actually played this session
(like a browser back button), rather than a new random pick — distinct from the 4 fixed
playlists' index-based Previous.

## Acceptance criteria

- Pressing Previous while in BGM mode plays the video that was played immediately before the
  current one in this session, and moves the "position" back one step in that history.
- Pressing Previous with no earlier history available (e.g. right after switching to BGM, on the
  very first video) is a no-op — does not error, does not wrap to some other video.
- Clicking a history entry directly in the track list (`bgm-011`) jumps to that point in history
  the same way repeated Previous presses would, rather than behaving differently.
- If Previous has been used to step back, and **Next** is then pressed, Next always picks a fresh
  video via `bgm-004` rather than replaying forward through history — anything "ahead" in the
  history at that point is discarded, not restored.
- This history is **in-memory only for the current app session** — it is not persisted, and starts
  empty again on every relaunch (distinct from the one persisted "last-played video," which is
  `bgm-009`'s concern, not this issue's).

## Notes

The "Next after Previous discards forward history" rule was an explicit decision during the
interview for this feature (a deliberate simplification over full browser-style back/forward) —
don't implement a redo stack.
