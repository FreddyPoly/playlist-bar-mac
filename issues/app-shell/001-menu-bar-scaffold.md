---
id: app-shell-001
title: Menu bar app scaffold
status: done
security: false
owner: agent
depends_on: []
spec_ref: "SPEC.md#platform--stack"
---

## Description

Create the Xcode project "Playlist Bar" as a SwiftUI macOS app using `MenuBarExtra` as the app's
only UI surface. No dock icon, no separate app window — this is a background/agent-style app
(`LSUIElement`). Start with an empty placeholder dropdown that opens/closes; all real content is
added by later issues.

## Acceptance criteria

- Project builds and runs from Xcode.
- A menu bar icon appears in the system menu bar.
- Clicking it opens/closes a dropdown (content can be a placeholder for now).
- No dock icon and no standalone app window appear anywhere.

## Notes

Target is macOS 26 (Tahoe) with Xcode already installed — no legacy macOS compatibility work
needed. The app is not signed/notarized/distributed; it's built and run locally only (per
SPEC.md's "Platform & stack" section).

**Implementation decision:** scaffolded as a Swift Package (`Package.swift` +
`Sources/PlaylistBar/`) rather than a hand-authored `.xcodeproj`, since there's no reliable
command-line way to generate a correct native Xcode project file. Xcode can open `Package.swift`
directly (File > Open) and build/run/debug it exactly like a native project, so this still
satisfies "built and run via Xcode." No dock icon is achieved via
`NSApp.setActivationPolicy(.accessory)` in `AppDelegate`, which is equivalent in effect to the
`LSUIElement` Info.plist key used by traditional app bundles.

**Verification note:** built successfully (`swift build`) and ran without crashing; confirmed via
`osascript`/System Events that the running process has `background only = true` (i.e. no Dock
icon). Could not get a pixel-level screenshot or interactive click-test of the menu bar dropdown
in this environment — `screencapture` and System Events UI scripting both failed due to missing
Screen Recording / Accessibility permissions for the terminal running this session. The
`MenuBarExtra` API is a standard, well-established mechanism for this, so this is expected to
work, but please visually confirm the icon and dropdown yourself (`swift run` from the project
directory) when convenient.

**Test framework:** project has no test suite yet — flagging per implement-issue guidance rather
than unilaterally introducing one. Worth a project-wide decision if/when test coverage is wanted.

**Code review:** `/code-review` could not be invoked automatically (reserved for explicit user
invocation) — worth running yourself if you want a second pass on this and the other issues in
this run.
