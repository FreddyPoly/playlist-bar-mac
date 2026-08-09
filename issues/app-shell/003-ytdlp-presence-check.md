---
id: app-shell-003
title: yt-dlp presence check
status: done
security: false
owner: agent
depends_on: [app-shell-001]
spec_ref: "SPEC.md#playback-engine"
---

## Description

On launch, check whether `yt-dlp` is available on PATH, exposing a simple available/unavailable
status the rest of the app can read (used by menu-bar-ui-005 to show install guidance).

## Acceptance criteria

- Returns "available" when yt-dlp is installed and resolvable on PATH.
- Returns "unavailable" otherwise, without crashing or hanging the app.
- The check uses a fixed, non-dynamic command (e.g. locating `yt-dlp` on PATH or running
  `yt-dlp --version`) — no user-controlled input involved.

## Notes

Per SPEC.md, yt-dlp is installed by the user via Homebrew — this app never installs or downloads
it itself.

Implemented as `YtDlpLocator.checkAvailability()` in `Sources/PlaylistBar/YtDlpAvailability.swift`,
returning a `YtDlpAvailability` enum (`.available(path:)` / `.unavailable`). Uses
`/usr/bin/env which yt-dlp` — a fixed command, no dynamic/user-controlled arguments.

Verified directly (outside the app, via a standalone `swift` script running the same source file)
in both states: returns `.unavailable` with no yt-dlp on PATH (the actual current state of this
machine), and `.available(path:)` with a fake `yt-dlp` shim added to PATH. Not yet wired into any
UI/startup flow — that's menu-bar-ui-005's job — so there's nothing in the running app to
interactively verify yet.

This is a synchronous, blocking call (spawns and waits on a subprocess) — fine for a one-off
startup check, but whoever wires this into the UI (menu-bar-ui-005) should call it off the main
thread to avoid blocking the UI at launch.

**Fixed (code review finding):** the original implementation relied on inherited PATH via
`env which yt-dlp`, which works from a terminal but not when the app is launched by Finder/login
item — GUI-launched processes get the system default PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), not
Homebrew's `/opt/homebrew/bin`. `checkAvailability()` now explicitly passes an augmented PATH
(Homebrew's `/opt/homebrew/bin` and `/usr/local/bin` prepended to the inherited PATH) to the
subprocess. Verified with `yt-dlp` actually installed (`brew install yt-dlp`, landed at
`/opt/homebrew/bin/yt-dlp`): the check still correctly returns `.available` even when run with
PATH forced down to the bare `/usr/bin:/bin:/usr/sbin:/sbin` GUI-launch default.
