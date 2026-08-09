---
id: system-integration-002
title: Media key (F7/F8/F9) support
status: done
security: false
owner: agent
depends_on: [playback-controller-002, system-integration-001]
spec_ref: "SPEC.md#native-macos-integration"
---

## Description

Handle system media key remote commands (previous/play-pause/next) via
`MPRemoteCommandCenter` so playback can be controlled system-wide even when the dropdown is
closed.

## Acceptance criteria

- Pressing F7/F8/F9 (or the equivalent on-screen/Touch Bar/Control Center media controls)
  controls playback identically to the in-dropdown transport buttons.
- Works whether or not the dropdown is currently open.

## Notes

Reset has no standard system media-key equivalent — only Previous/Play-Pause/Next are wired to
hardware/system media commands, matching typical macOS media app behavior.

Implemented as `setUpRemoteCommands()`, called once from `PlaybackController.init()`, wiring
`MPRemoteCommandCenter.shared()`'s `previousTrackCommand`/`nextTrackCommand`/
`togglePlayPauseCommand` to `previous()`/`next()`/`togglePlayPause()` — these are what F7/F8/F9
and most system media UI send. Also separately wired `playCommand`/`pauseCommand` (some clients,
like Control Center's own play/pause buttons, send discrete play/pause rather than a single
toggle), each guarded to only act in the correct direction (`playCommand` no-ops if already
playing, `pauseCommand` no-ops if already paused) so a stray duplicate command can't flip state
the wrong way. Each handler fires the corresponding `async` controller method inside
`Task { @MainActor in ... }` and returns `.success` immediately, since
`MPRemoteCommandHandler` closures must return synchronously.

**Verification limitation:** confirmed all five commands report `isEnabled == true` after setup
(set automatically by `addTarget`, proving registration succeeded with no runtime errors) and that
the app launches and runs without crashing with this wired in. Could not simulate an actual
hardware F7/F8/F9 press or a Control Center button click — there's no public API to synthesize a
system media-key event from within the app itself, and (as with the other menu-bar-ui/startup
issues) no Accessibility permission for synthetic UI interaction in this environment. The handler
pattern used here matches Apple's standard documented `MPRemoteCommandCenter` usage closely (not
a novel/risky approach), which somewhat offsets the lack of live end-to-end testing, but this is
worth a real press of the media keys yourself to confirm.
