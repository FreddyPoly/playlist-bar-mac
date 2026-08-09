---
id: app-shell-002
title: Quit menu item
status: done
security: false
owner: agent
depends_on: [app-shell-001]
spec_ref: "SPEC.md#ui-menu-bar-dropdown"
---

## Description

Add a "Quit" item to the dropdown that terminates the app.

## Acceptance criteria

- The dropdown has a visible "Quit" action.
- Selecting it exits the app cleanly (no orphaned processes, e.g. any in-flight yt-dlp subprocess
  is not left running).

## Notes

Implemented as a "Quit" `Button` in `ContentView` calling `NSApplication.shared.terminate(nil)` —
the standard, correct way to terminate a SwiftUI/AppKit app.

No subprocess cleanup needed yet: there's no `Process` (yt-dlp) usage in the codebase at this
point. Once playback-engine issues land and introduce yt-dlp subprocesses, revisit whether
`terminate(nil)` alone reliably tears those down or whether explicit cleanup is needed in
`applicationWillTerminate`.

Build verified (`swift build`); could not interactively click-test the Quit button in this
environment (same missing Accessibility/Screen Recording permissions noted in app-shell-001) —
worth a quick manual check.
