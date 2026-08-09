---
id: startup-001
title: Launch-at-Login toggle
status: done
security: false
owner: agent
depends_on: [app-shell-001]
spec_ref: "SPEC.md#startup--login-item"
---

## Description

Add a "Launch at Login" toggle in the dropdown backed by `SMAppService`, letting the user
enable/disable starting the app automatically at macOS login.

## Acceptance criteria

- Toggling on registers the app as a login item (verifiable in System Settings > General > Login
  Items & Extensions).
- Toggling off unregisters it.
- The toggle's displayed state reflects the actual current registration status whenever the
  dropdown is opened (not just the last value the user set in-app).

## Notes

`SMAppService` is available on the target macOS version (26/Tahoe) — no fallback for older macOS
needed per SPEC.md.

**Blocked — real, structural issue found via live testing (with explicit user permission to
register/unregister a real login item for verification).** Implemented `LoginItemManager`
(`Sources/PlaylistBar/LoginItemManager.swift`) with the correct `SMAppService.mainApp.register()`/
`.unregister()` API usage. Testing it against a throwaway `swift script.swift` process showed the
call succeeding — but that's not a faithful test, since `swift script.swift` runs under the Swift
interpreter's own process identity, not the real app. Re-tested against the actual compiled
`.build/debug/PlaylistBar` binary (via a temporary, since-removed debug hook) and it **throws**:
`SMAppServiceErrorDomain Code=22 "Invalid argument"`. Confirmed via `sfltool dumpbtm` that nothing
was actually registered — no stray login item was left behind.

**Root cause:** `SMAppService` requires the calling process to be a proper `.app` bundle with a
valid `Info.plist`/`CFBundleIdentifier` (and typically a code signature, even ad-hoc). This
project is currently a Swift Package producing a bare Mach-O executable
(`.build/debug/PlaylistBar`), not a `.app` bundle — a decision made in app-shell-001 specifically
so Xcode could open `Package.swift` directly without a hand-authored `.xcodeproj`. That decision
is exactly what breaks this feature: there's no `Info.plist` for `SMAppService` to identify the
app by.

This isn't something to guess a fix for — it's a real architectural fork with tradeoffs, so I'm
leaving this issue `in-progress` and flagging it rather than forcing a green checkmark. See the
chat for the options being surfaced to the user.

**Resolved.** Per user direction, added a lightweight packaging step rather than restructuring
the whole project into an Xcode-managed `.app` target: `Packaging/Info.plist` (bundle id
`com.studiobleumoutarde.PlaylistBar`, `LSUIElement=true`, min system version 13.0) and
`Scripts/package-app.sh`, which builds the executable (`swift build`), assembles it into
`dist/PlaylistBar.app/Contents/{MacOS,Resources}`, copies in the Info.plist, and ad-hoc code-signs
it (`codesign --force --deep --sign -`). Day-to-day development is unaffected — `swift build`/
`swift run` still work exactly as before; the packaging script only matters for testing/using
Launch-at-Login (or eventually distributing the app).

Added `LoginItemManager` (`Sources/PlaylistBar/LoginItemManager.swift`) wrapping
`SMAppService.mainApp`, and a `Toggle("Launch at Login", ...)` in `ContentView`, re-syncing from
actual system state via `.onAppear` (Login Items can change outside the app, e.g. directly in
System Settings, so the toggle shouldn't just trust its last in-app value).

Verified against the **real packaged `.app` bundle** (not the bare `swift build` executable,
which is exactly what was broken) via a temporary, since-removed debug hook, checking
`sfltool dumpbtm` (the system's background-task-management database) before and after each step:
- `register()` succeeded (previously threw `Invalid argument`) and a genuine entry for
  "PlaylistBar" appeared in `dumpbtm` with `Disposition: [enabled, allowed, notified]`, the
  correct bundle identifier, and the correct `.app` path.
- `unregister()` succeeded and the same entry's disposition changed to `[disabled, allowed,
  notified]` — matching the pattern of other legitimately-inactive entries in the same database
  (e.g. Xcode's own disabled entry), confirming it's genuinely deregistered, not just cosmetically
  toggled in-app.
- Confirmed via `dumpbtm` after all testing that no login item was left in an active/enabled
  state.

Could not click-test the actual `Toggle` UI element itself (same Accessibility-permission
limitation as other menu-bar-ui issues), but the underlying `setEnabled`/`register`/`unregister`
path it calls into is exactly what was verified above against the real bundle.
