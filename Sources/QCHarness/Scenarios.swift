import AppKit
import Foundation

struct ScenarioContext {
    let controller: PopoverController
    let screenshotDir: String
    let sourceRoot: String
    let skipYtdlpOutage: Bool
}

private func screenshotPath(_ context: ScenarioContext, _ name: String) -> String {
    "\(context.screenshotDir)/\(name).png"
}

/// One entry per scenario: name, bookkeeping metadata, and the body that either returns a
/// human-readable success message or throws (any `Error`, its `localizedDescription`/
/// `description` becomes the failure message).
struct Scenario {
    let name: String
    let category: ScenarioCategory
    let relatedIssues: [String]
    let takesScreenshot: Bool
    let body: (ScenarioContext) throws -> String
}

/// The full suite, in the order a real QC walkthrough would naturally hit them — later scenarios
/// build on state left by earlier ones (e.g. a playlist has to be selected before transport
/// controls mean anything), same structure the `qc` skill itself uses for a manual pass.
let allScenarios: [Scenario] = [
    Scenario(
        name: "01-status-item-present",
        category: .ui,
        relatedIssues: ["menu-bar-ui-004"],
        takesScreenshot: false
    ) { ctx in
        let label = try ctx.controller.statusItemLabel()
        guard label == "Playing" || label == "Paused" else {
            throw HarnessError(description: "status item label was \(label.isEmpty ? "<empty>" : label), expected Playing/Paused")
        }
        return "status item present, label=\(label)"
    },

    Scenario(
        name: "02-open-popover",
        category: .ui,
        relatedIssues: [],
        takesScreenshot: true
    ) { ctx in
        _ = try ctx.controller.window()
        guard ctx.controller.isPopoverOpen else { throw HarnessError(description: "popover reports closed after opening") }
        return "popover opened"
    },

    Scenario(
        name: "03-title-label",
        category: .ui,
        relatedIssues: [],
        takesScreenshot: false
    ) { ctx in
        let window = try ctx.controller.window()
        guard let title = ctx.controller.find(identifier: "PlaylistBar.title", in: window) else {
            throw HarnessError(description: "title label not found")
        }
        // SwiftUI `Text`'s literal content bridges to kAXValueAttribute as a plain string.
        let text = AX.value(title)
        guard text == "Playlist Bar" else {
            throw HarnessError(description: "title text was \(text.isEmpty ? "<empty>" : text), expected 'Playlist Bar'")
        }
        return "title label correct"
    },

    Scenario(
        name: "04-no-banners-at-baseline",
        category: .ui,
        relatedIssues: [],
        takesScreenshot: false
    ) { ctx in
        let window = try ctx.controller.window()
        let error = ctx.controller.errorBannerText(in: window)
        let missing = ctx.controller.ytdlpMissingBannerText(in: window)
        guard error == nil, missing == nil else {
            throw HarnessError(description: "unexpected banner at startup: error=\(error ?? "nil") missing=\(missing ?? "nil")")
        }
        return "no error banners at baseline"
    },

    Scenario(
        name: "05-playlist-picker-enumeration",
        category: .ui,
        relatedIssues: [],
        takesScreenshot: false
    ) { ctx in
        let window = try ctx.controller.window()
        Input.dismissAnyOpenMenu()
        guard let picker = ctx.controller.find(identifier: "PlaylistBar.playlistPicker", in: window) else {
            throw HarnessError(description: "no picker")
        }
        guard AX.press(picker) else { throw HarnessError(description: "failed to open picker menu") }
        guard let menu = waitUntil(timeout: 2, { AX.children(picker).first }) else {
            throw HarnessError(description: "picker menu never appeared")
        }
        let titles = AX.children(menu).map(AX.title)
        Input.dismissAnyOpenMenu()
        let expected = ["Select a playlist", "Rock3", "Drum'N'Bass", "Tranquille", "Jazz", "BGM"]
        guard titles == expected else {
            throw HarnessError(description: "picker entries were \(titles), expected \(expected)")
        }
        return "picker has all 6 expected entries in order"
    },

    Scenario(
        name: "06-switch-to-rock3",
        category: .ui,
        relatedIssues: [],
        takesScreenshot: true
    ) { ctx in
        try switchAndVerify(playlist: "Rock3", context: ctx)
    },

    Scenario(
        name: "07-scrollview-not-collapsed",
        category: .regression,
        relatedIssues: ["menu-bar-ui-003"],
        takesScreenshot: false
    ) { ctx in
        let window = try ctx.controller.window()
        guard let height = ctx.controller.trackListFrameHeight(in: window) else {
            throw HarnessError(description: "could not read track list frame")
        }
        guard height >= 100 else {
            throw HarnessError(description: "track list height was \(height)pt, expected >= 100pt (ScrollView collapse regression)")
        }
        return "track list height = \(height)pt"
    },

    Scenario(
        name: "08-icon-reflects-play-state",
        category: .regression,
        relatedIssues: ["menu-bar-ui-004"],
        takesScreenshot: false
    ) { ctx in
        let window = try ctx.controller.window()
        // Wait out any in-flight stream resolution from the previous scenario's playlist switch
        // first — toggling while `isResolvingTrack`/`isLoading` is still true races a real
        // network-bound `play(startingAt:)` call, not a steady-state toggle.
        guard waitUntil(timeout: 40, interval: 0.25, { ctx.controller.playPauseLabel(in: window) == "Loading" ? nil : true }) == true else {
            throw HarnessError(description: "track never finished resolving before toggle test")
        }
        let before = ctx.controller.playPauseLabel(in: window)
        let iconBefore = try ctx.controller.statusItemLabel()
        try ctx.controller.pressButton(identifier: "PlaylistBar.playPauseButton", in: window)
        guard let iconAfter = waitUntil(timeout: 10, interval: 0.25, { () -> String? in
            let current = try? ctx.controller.statusItemLabel()
            return (current != iconBefore) ? current : nil
        }) else {
            throw HarnessError(description: "status item label didn't change after play/pause toggle (stuck at \(iconBefore))")
        }
        guard iconAfter == "Playing" || iconAfter == "Paused" else {
            throw HarnessError(description: "status item label after toggle was \(iconAfter), expected Playing/Paused")
        }
        return "icon label \(iconBefore) -> \(iconAfter) (button was \(before ?? "?"))"
    },

    Scenario(
        name: "09-hung-loading-spinner-bounded",
        category: .regression,
        relatedIssues: ["volume-control-007"],
        takesScreenshot: false
    ) { ctx in
        let window = try ctx.controller.window()
        try ctx.controller.pressButton(identifier: "PlaylistBar.nextButton", in: window)
        let start = Date()
        // volume-control-007's fix bounds any single wait to 5s + fallback overhead, but real
        // yt-dlp/ffmpeg network calls (this isn't mocked — see CLAUDE.md) can still legitimately
        // take longer end-to-end; 40s comfortably distinguishes that from the original bug, which
        // was a structurally infinite hang ("stuck for several minutes", confirmed live).
        let cleared = waitUntil(timeout: 40, interval: 0.25) { () -> Bool? in
            let label = ctx.controller.playPauseLabel(in: window)
            return label == "Loading" ? nil : true
        }
        let elapsed = Date().timeIntervalSince(start)
        guard cleared == true else {
            throw HarnessError(description: "loading spinner still showing after \(String(format: "%.1f", elapsed))s (hung-spinner regression)")
        }
        return "loading state cleared in \(String(format: "%.1f", elapsed))s"
    },

    Scenario(
        name: "10-transport-previous-and-reset",
        category: .ui,
        relatedIssues: [],
        takesScreenshot: false
    ) { ctx in
        let window = try ctx.controller.window()
        try ctx.controller.pressButton(identifier: "PlaylistBar.previousButton", in: window)
        // Previous/Reset each trigger a real, network-bound `play(startingAt:)` resolve (per
        // SPEC.md, Previous/Next/Reset always start fresh, never resuming a cached position) — a
        // fixed short sleep here previously raced that resolve and produced a false failure; poll
        // for the loading state to clear instead of guessing a duration.
        guard waitUntil(timeout: 40, interval: 0.25, { ctx.controller.playPauseLabel(in: window) == "Loading" ? nil : true }) == true else {
            throw HarnessError(description: "Previous never finished resolving")
        }
        try ctx.controller.pressButton(identifier: "PlaylistBar.resetButton", in: window)
        guard waitUntil(timeout: 40, interval: 0.25, { ctx.controller.playPauseLabel(in: window) == "Loading" ? nil : true }) == true else {
            throw HarnessError(description: "Reset never finished resolving")
        }
        let rows = waitUntil(timeout: 5, interval: 0.25) { () -> [(label: String, isCurrent: Bool)]? in
            let current = ctx.controller.trackListRows(in: window)
            return current.first?.isCurrent == true ? current : nil
        }
        guard let firstRow = rows?.first, firstRow.isCurrent else {
            throw HarnessError(description: "after Reset, first visible row should be current; rows=\(rows ?? ctx.controller.trackListRows(in: window))")
        }
        return "Previous + Reset landed on track 1"
    },

    Scenario(
        name: "11-click-to-play-track-row",
        category: .ui,
        relatedIssues: [],
        takesScreenshot: false
    ) { ctx in
        let window = try ctx.controller.window()
        let rows = ctx.controller.trackListRows(in: window)
        guard rows.count >= 3 else { throw HarnessError(description: "not enough rows to test click-to-play (\(rows.count))") }
        let target = rows[2].label
        try ctx.controller.clickTrackRow(labeled: target, in: window)
        Thread.sleep(forTimeInterval: 1.0)
        let after = ctx.controller.trackListRows(in: window)
        guard after.first(where: { $0.label == target })?.isCurrent == true else {
            throw HarnessError(description: "clicked row '\(target)' did not become current")
        }
        return "clicked row became current: \(target)"
    },

    Scenario(
        name: "12-volume-slider-in-range",
        category: .ui,
        relatedIssues: [],
        takesScreenshot: false
    ) { ctx in
        let window = try ctx.controller.window()
        guard let slider = ctx.controller.find(identifier: "PlaylistBar.volumeSlider", in: window),
              let value = AX.doubleValue(slider) else {
            throw HarnessError(description: "volume slider not found or not numeric")
        }
        guard (0...1).contains(value) else {
            throw HarnessError(description: "volume slider value \(value) out of 0...1 range")
        }
        return "volume slider value = \(value)"
    },

    Scenario(
        name: "13-switch-to-remaining-fixed-playlists",
        category: .ui,
        relatedIssues: [],
        takesScreenshot: false
    ) { ctx in
        var messages: [String] = []
        for name in ["Drum'N'Bass", "Tranquille", "Jazz"] {
            messages.append(try switchAndVerify(playlist: name, context: ctx))
        }
        return messages.joined(separator: "; ")
    },

    Scenario(
        name: "14-switch-to-bgm",
        category: .ui,
        relatedIssues: ["bgm-010"],
        takesScreenshot: true
    ) { ctx in
        let window = try ctx.controller.window()
        try ctx.controller.selectPlaylist(named: "BGM", in: window)
        guard waitUntil(timeout: 20, interval: 0.3, { ctx.controller.currentPlaylistName() == "BGM" ? true : nil }) == true else {
            throw HarnessError(description: "picker never showed BGM as selected")
        }
        let window2 = try ctx.controller.window()
        guard waitUntil(timeout: 30, interval: 0.5, { ctx.controller.trackListRows(in: window2).isEmpty ? nil : true }) == true else {
            throw HarnessError(description: "BGM track list never populated (startup-latency regression, playback-engine's preferProgressive fix)")
        }
        return "BGM active with \(ctx.controller.trackListRows(in: window2).count) history row(s)"
    },

    Scenario(
        name: "15-bgm-switchback-no-duplicate-history",
        category: .regression,
        relatedIssues: ["bgm-006"],
        takesScreenshot: false
    ) { ctx in
        let window = try ctx.controller.window()
        guard ctx.controller.currentPlaylistName(in: window) == "BGM" else {
            throw HarnessError(description: "precondition failed: BGM not active (did scenario 14 fail?)")
        }
        let before = ctx.controller.trackListRows(in: window)
        try ctx.controller.selectPlaylist(named: "Rock3", in: window)
        Thread.sleep(forTimeInterval: 1.5)
        let window2 = try ctx.controller.window()
        try ctx.controller.selectPlaylist(named: "BGM", in: window2)
        guard waitUntil(timeout: 10, interval: 0.3, { ctx.controller.currentPlaylistName() == "BGM" ? true : nil }) == true else {
            throw HarnessError(description: "did not switch back to BGM")
        }
        let window3 = try ctx.controller.window()
        let after = waitUntil(timeout: 10, interval: 0.3) { () -> [(label: String, isCurrent: Bool)]? in
            let rows = ctx.controller.trackListRows(in: window3)
            return rows.isEmpty ? nil : rows
        } ?? []
        let beforeLabels = before.map(\.label)
        let afterLabels = after.map(\.label)
        guard beforeLabels == afterLabels else {
            throw HarnessError(
                description: "BGM history changed across switch-away/switch-back: before=\(beforeLabels) after=\(afterLabels) (duplicate-history regression)"
            )
        }
        return "BGM history unchanged across switch-away/switch-back (\(after.count) rows)"
    },

    Scenario(
        name: "16-duration-watchdog-code-invariant",
        category: .codeInvariant,
        relatedIssues: ["playback-engine-005"],
        takesScreenshot: false
    ) { ctx in
        let path = "\(ctx.sourceRoot)/Sources/PlaylistBar/AudioPlayer.swift"
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw HarnessError(description: "could not read \(path)")
        }
        // Not a live replay: the original bug only manifested after several minutes of real
        // playback (AVFoundation's own duration estimate for these streams is ~2x too long), so
        // reproducing it live would mean playing a full track end-to-end. This instead guards the
        // fix's actual mechanism — a wall-clock watchdog keyed off the *trusted* duration
        // (yt-dlp's own metadata, passed into `load(url:duration:...)`), not AVFoundation's own
        // (mis-)estimate — so a regression that deletes or bypasses it fails this check.
        guard source.contains("knownEndWatchdog") else {
            throw HarnessError(description: "AudioPlayer.swift no longer has a knownEndWatchdog — trusted-duration end detection may have regressed")
        }
        guard source.contains("duration + Self.knownEndGraceSeconds") else {
            throw HarnessError(description: "AudioPlayer.swift's watchdog no longer keys off the trusted `duration` parameter — may be back to trusting AVFoundation's own (~2x too long) estimate")
        }
        return "trusted-duration watchdog present in AudioPlayer.swift"
    },

    Scenario(
        name: "17-ytdlp-outage-error-handling",
        category: .regression,
        relatedIssues: ["menu-bar-ui-005"],
        takesScreenshot: true
    ) { ctx in
        if ctx.skipYtdlpOutage {
            throw SkippedScenario(reason: "skipped via --skip-ytdlp-outage")
        }
        let window = try ctx.controller.window()
        try ctx.controller.selectPlaylist(named: "Rock3", in: window)
        Thread.sleep(forTimeInterval: 1.5)
        let window2 = try ctx.controller.window()
        let rowsBefore = ctx.controller.trackListRows(in: window2)
        guard !rowsBefore.isEmpty else { throw HarnessError(description: "no tracks loaded before outage test") }

        let candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
        let fm = FileManager.default
        var hidden: [(from: String, to: String)] = []
        defer {
            for (from, to) in hidden { try? fm.moveItem(atPath: to, toPath: from) }
        }
        for path in candidates where fm.fileExists(atPath: path) {
            let hiddenPath = path + ".qc-hidden"
            try fm.moveItem(atPath: path, toPath: hiddenPath)
            hidden.append((from: path, to: hiddenPath))
        }
        guard !hidden.isEmpty else {
            throw HarnessError(description: "no yt-dlp binary found at \(candidates) to hide — cannot exercise this scenario on this machine")
        }

        try ctx.controller.pressButton(identifier: "PlaylistBar.nextButton", in: window2)

        let window3 = try ctx.controller.window()
        _ = waitUntil(timeout: 10, interval: 0.3) { () -> Bool? in
            ctx.controller.errorBannerText(in: window3) != nil || ctx.controller.ytdlpMissingBannerText(in: window3) != nil ? true : nil
        }
        let error = ctx.controller.errorBannerText(in: window3)
        let missing = ctx.controller.ytdlpMissingBannerText(in: window3)
        let bannerCount = [error, missing].compactMap { $0 }.count
        let rowsAfter = ctx.controller.trackListRows(in: window3)

        guard bannerCount <= 1 else {
            throw HarnessError(description: "both error and yt-dlp-missing banners shown at once (duplicate-banner regression): error=\(error ?? "") missing=\(missing ?? "")")
        }
        guard !rowsAfter.isEmpty else {
            throw HarnessError(description: "track list vanished after resolution failure (was \(rowsBefore.count) rows, now 0) — vanishing-track-list regression")
        }
        return "at most one banner shown (\(bannerCount)), track list intact (\(rowsAfter.count) rows)"
    },

    Scenario(
        name: "18-menu-bar-title-truncation-obsolete",
        category: .obsolete,
        relatedIssues: ["menu-bar-ui-004"],
        takesScreenshot: false
    ) { _ in
        // The 40-then-20-character menu bar *title text* truncation this scenario originally
        // covered was removed entirely on 2026-08-12 in favor of the icon-only label (see
        // CLAUDE.md's "Icon-only label" note) — there is no longer any title text to truncate.
        // Recorded here (not silently dropped) so the regression list stays a complete history;
        // scenario 08 covers what replaced it.
        throw SkippedScenario(reason: "superseded 2026-08-12: menu bar label is icon-only now, no title text exists to truncate")
    },

    Scenario(
        name: "19-launch-at-login-toggle-present",
        category: .ui,
        relatedIssues: [],
        takesScreenshot: false
    ) { ctx in
        // Read-only: actually toggling this makes a real, persistent change to the user's macOS
        // Login Items — out of scope for an automated check to do unprompted.
        let window = try ctx.controller.window()
        guard let toggle = ctx.controller.find(identifier: "PlaylistBar.launchAtLoginToggle", in: window) else {
            throw HarnessError(description: "launch-at-login toggle not found")
        }
        return "toggle present, current value = \(AX.value(toggle))"
    },

    Scenario(
        name: "20-quit-button-present",
        category: .ui,
        relatedIssues: [],
        takesScreenshot: false
    ) { ctx in
        // Read-only, deliberately never pressed — clicking it would terminate the app under test.
        let window = try ctx.controller.window()
        guard let quit = ctx.controller.find(identifier: "PlaylistBar.quitButton", in: window) else {
            throw HarnessError(description: "quit button not found")
        }
        guard AX.isEnabled(quit) else { throw HarnessError(description: "quit button not enabled") }
        return "quit button present and enabled (not pressed)"
    }
]

struct SkippedScenario: Error {
    let reason: String
}

private func switchAndVerify(playlist name: String, context ctx: ScenarioContext) throws -> String {
    let window = try ctx.controller.window()
    try ctx.controller.selectPlaylist(named: name, in: window)
    guard waitUntil(timeout: 15, interval: 0.3, { ctx.controller.currentPlaylistName() == name ? true : nil }) == true else {
        throw HarnessError(description: "picker never showed \(name) as selected")
    }
    let window2 = try ctx.controller.window()
    guard waitUntil(timeout: 30, interval: 0.3, { ctx.controller.trackListRows(in: window2).isEmpty ? nil : true }) == true else {
        throw HarnessError(description: "\(name)'s track list never populated")
    }
    return "\(name): \(ctx.controller.trackListRows(in: window2).count) rows"
}

func runAllScenarios(context: ScenarioContext) -> [ScenarioResult] {
    var results: [ScenarioResult] = []
    for scenario in allScenarios {
        let start = Date()
        var status: ScenarioStatus = .passed
        var message = ""
        var screenshotFile: String?
        do {
            message = try scenario.body(context)
            if scenario.takesScreenshot {
                let path = screenshotPath(context, scenario.name)
                if (try? context.controller.screenshot(to: path)) == true {
                    screenshotFile = path
                }
            }
        } catch let skipped as SkippedScenario {
            status = .skipped
            message = skipped.reason
        } catch {
            status = .failed
            message = String(describing: error)
        }
        let duration = Date().timeIntervalSince(start)
        let result = ScenarioResult(
            name: scenario.name,
            category: scenario.category,
            status: status,
            message: message,
            durationSeconds: duration,
            screenshot: screenshotFile,
            relatedIssues: scenario.relatedIssues
        )
        results.append(result)
        let marker = status == .passed ? "PASS" : (status == .skipped ? "SKIP" : "FAIL")
        FileHandle.standardError.write("[\(marker)] \(scenario.name) (\(String(format: "%.1f", duration))s): \(message)\n".data(using: .utf8)!)
    }
    return results
}
