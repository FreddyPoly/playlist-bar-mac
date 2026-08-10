---
id: bgm-007
title: Session-only Previous history navigation
status: done
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

## Implemented (2026-08-10)

Added `private var bgmHistoryPosition: Int?` to `PlaybackController` — `nil` means "at the live
edge" (`bgmHistory.last`), a real index means "displaying/playing that point in history."
`previousBGM()` computes `newPosition = (bgmHistoryPosition ?? bgmHistory.count - 1) - 1`, no-ops
if that's out of range, otherwise replays `bgmHistory[newPosition]` via `playBGM` with a new
`appendToHistory: Bool` parameter set to `false` (added to `playBGM`'s signature — a history
walk-back replays a track already in `bgmHistory`, so it must not grow it again).
`selectBGMHistoryEntry(at:)` is the click-to-jump equivalent (bgm-011 will wire a UI button to it)
— same effect as repeated `previousBGM()` calls, landing directly on the given index; clicking the
last entry resets to the live edge (`bgmHistoryPosition = nil`) rather than leaving a stale
now-redundant position set.

`advanceBGM` (shared by manual Next and auto-advance, from `bgm-006`) now checks
`bgmHistoryPosition` before making a fresh pick: if set, truncates `bgmHistory` to
`prefix(position + 1)` (discarding everything "ahead" of where you'd walked back to) and resets
the position to `nil`, *then* proceeds with its normal fresh-pick-and-append. `switchToBGM()`
resets `bgmHistoryPosition = nil` on every call (even though `bgmHistory` itself deliberately
survives a switch-away-and-back, per `bgm-006`) — re-entering BGM always resumes at the live edge,
not stuck mid-walk-back from before you left.

**Verification**: standalone script mirroring the real control flow (fake resolver, since
`StreamResolver` integration is already proven in `bgm-006`/earlier issues) covering: a fresh
switch seeds a one-entry history and Previous on it is a no-op; building history via repeated Next
then walking all the way back via repeated Previous (verified at each step, including a repeated
Previous at the oldest entry staying a no-op rather than erroring or wrapping); Next after a
walk-back both plays a genuinely fresh pick *and* correctly truncates the discarded forward
entries while preserving everything up to and including the walked-back-to point; click-to-jump
(`selectBGMHistoryEntry`-equivalent) behaves identically to walking back via repeated Previous,
including that a *subsequent* Next after a click-to-jump also discards forward history; and the
edge case that clicking the current/live-edge entry itself does **not** cause a following Next to
incorrectly discard anything (this was deliberately tested, not just assumed, since it's the one
case where "position" should resolve back to the nil/live-edge state rather than a real index).
All passed. `swift build` succeeds with no warnings.

**Review**: manual pass in place of `/code-review` (see `bgm-002`'s Notes). `security: false` — no
new subprocess/parsing surface; pure in-memory state/array manipulation plus reuse of the already-
reviewed `playBGM` resolve path. No findings.
