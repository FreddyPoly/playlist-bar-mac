---
id: startup-002
title: Idle launch with restored selection (no auto-play)
status: done
security: false
owner: agent
depends_on: [player-state-002, playback-controller-001]
spec_ref: "SPEC.md#startup--login-item"
---

## Description

When the app launches (including via login item), restore the last active playlist and its
last-played track (from player-state) in the UI/current-track display, but do not start playback
automatically — playback starts only when the user presses Play.

## Acceptance criteria

- Quitting the app while playing, then relaunching, shows the same playlist/track selected and
  ready but paused (no audio starts on its own).
- Pressing Play resumes from exactly that track.
- This holds both for a normal manual relaunch and a login-item launch.

## Notes

This is the one place SPEC.md explicitly overrides "switching to a playlist plays it
immediately" (SPEC.md's behavior rules) — launch-time restoration is intentionally passive to
avoid music starting unexpectedly at boot.

Added `PlaybackController.restoreLastSession()`: looks up the last active playlist slug
(player-state-002) and its saved track (player-state-001), loads (cache-first) via the same
`loadAndDetermineStartIndex` helper `switchTo` uses (factored out of `switchTo` specifically for
this reuse — both need "load + figure out which index to land on", they just diverge on whether
to actually play it), and sets `currentIndex` directly **without** calling `play()`. Wired to run
at actual app launch by attaching `.task { await controller.restoreLastSession() }` to the
`MenuBarExtra`'s **label**, not `ContentView` — the label is instantiated immediately when the
menu bar item is created, while the dropdown content (and its own `.task` from menu-bar-ui-005)
is only created once the user first opens the dropdown, which would be too late to restore the
menu bar title (menu-bar-ui-004) before that.

**Real bug caught and fixed by actually testing this, not just building it:** the first version
left `togglePlayPause()`'s "start playing" branch calling `player.play()` unconditionally. That's
correct for every other flow (they all call `player.load()` first), but after
`restoreLastSession()`, `currentIndex` is set for *display* only — nothing has ever been loaded
into the underlying `AVPlayer`. Pressing Play for the first time after a restored launch would
have silently done nothing (`AVPlayer.play()` with no item loaded is a harmless no-op) — the one
button the user needs most right after "idle launch" wouldn't have worked. Fixed by adding a
`hasLoadedCurrentTrack` flag (true once a URL has actually reached `player.load`, false after
`restoreLastSession()` or any state-clearing path) and having `togglePlayPause()` (now `async`,
updated its `ContentView` call site accordingly) resolve-and-play fresh when it's false instead of
assuming an item is already loaded.

Verified end-to-end: no prior session → `restoreLastSession()` is a safe no-op (`currentPlaylist`
stays `nil`). A real "previous session" (played Jazz, advanced to index 2) restored via a **brand
new `PlaybackController` instance** (genuinely simulating a fresh launch, not reusing state)
correctly showed `currentPlaylist: jazz`, all 178 tracks, `currentIndex: 2`, and — the acceptance
criterion this issue is actually about — `isPlaying` stayed `false`. Then confirmed the fix:
the first `togglePlayPause()` after that restore correctly resolved and started real playback
(`isPlaying` → `true`, same index), and a second toggle correctly paused it.
