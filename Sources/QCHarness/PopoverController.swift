import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct HarnessError: Error, CustomStringConvertible {
    let description: String
}

/// Everything the scenario suite needs to drive one running instance of the packaged app:
/// finding it, opening/closing its menu-bar popover, reading its accessibility tree, clicking
/// things in it, and screenshotting it. One instance per `qcharness run` invocation.
final class PopoverController {
    let bundleIdentifier: String
    private(set) var pid: pid_t
    private let appElement: AXUIElement

    init(bundleIdentifier: String) throws {
        self.bundleIdentifier = bundleIdentifier
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            throw HarnessError(description: "no running app with bundle id \(bundleIdentifier)")
        }
        self.pid = running.processIdentifier
        self.appElement = AXUIElementCreateApplication(running.processIdentifier)
    }

    // MARK: - Status item

    /// The single `AXMenuBarItem` this app's `MenuBarExtra` creates — scoped to this app only
    /// (`AXExtrasMenuBar` is per-application, not the whole system menu bar), so no filtering
    /// against other apps' status items is needed.
    private func statusItem() throws -> AXUIElement {
        guard let extrasMenuBar: AXUIElement = AX.attribute(appElement, "AXExtrasMenuBar") else {
            throw HarnessError(description: "app has no AXExtrasMenuBar (status item not found)")
        }
        let items = AX.children(extrasMenuBar)
        guard let item = items.first else {
            throw HarnessError(description: "AXExtrasMenuBar has no status item children")
        }
        return item
    }

    /// Reads the status item's accessibility label without opening the popover — this is the
    /// "Playing"/"Paused" label PlaylistBarApp.swift sets on the menu bar icon (icon-only-label
    /// regression coverage, menu-bar-ui-004).
    func statusItemLabel() throws -> String {
        AX.title(try statusItem())
    }

    private func currentWindowInfo() -> (frame: CGRect, windowNumber: CGWindowID)? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in list where (window[kCGWindowOwnerPID as String] as? pid_t) == pid {
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let number = window[kCGWindowNumber as String] as? CGWindowID else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if rect.width > 0, rect.height > 0 { return (rect, number) }
        }
        return nil
    }

    /// The popover is an `NSPanel`-style window at the status-bar layer — it never shows up in
    /// the app's own `kAXWindowsAttribute` (confirmed live while building this harness), so it
    /// has to be located via `CGWindowListCopyWindowInfo` (by owning pid) and then hit-tested
    /// into an `AXUIElement` via `AXUIElementCopyElementAtPosition` on the system-wide element.
    private func popoverWindowElement() -> AXUIElement? {
        guard let (frame, _) = currentWindowInfo() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(systemWide, Float(frame.midX), Float(frame.midY), &elementRef)
        guard status == .success, var current = elementRef else { return nil }
        for _ in 0..<12 {
            if AX.role(current) == "AXWindow" { return current }
            guard let parent: AXUIElement = AX.attribute(current, kAXParentAttribute) else { return current }
            current = parent
        }
        return current
    }

    var isPopoverOpen: Bool { currentWindowInfo() != nil }

    /// Idempotent: presses the status item only if the popover isn't already open.
    @discardableResult
    func ensurePopoverOpen(timeout: TimeInterval = 5) throws -> AXUIElement {
        if let existing = popoverWindowElement() { return existing }
        AX.press(try statusItem())
        guard let window = waitUntil(timeout: timeout, interval: 0.1, { popoverWindowElement() }) else {
            throw HarnessError(description: "popover did not open within \(timeout)s of pressing the status item")
        }
        return window
    }

    func closePopover() {
        guard isPopoverOpen else { return }
        Input.dismissAnyOpenMenu()
        if isPopoverOpen, let item = try? statusItem() {
            AX.press(item)
        }
    }

    // MARK: - Reading the popover

    func window() throws -> AXUIElement {
        try ensurePopoverOpen()
    }

    func find(identifier: String, in window: AXUIElement) -> AXUIElement? {
        AX.findFirst(in: window, identifier: identifier)
    }

    /// All `AXButton`s carrying a non-empty description (label) inside the track list —
    /// i.e. every visible row, fixed-playlist or BGM. Order matches on-screen top-to-bottom order.
    func trackListRows(in window: AXUIElement) -> [(label: String, isCurrent: Bool)] {
        guard let trackList = find(identifier: "PlaylistBar.trackList", in: window) else { return [] }
        return AX.findAll(in: trackList, role: "AXButton")
            .map { (AX.label($0), AX.value($0) == "current") }
            .filter { !$0.label.isEmpty }
    }

    // MARK: - Actions

    /// Real click at the element's on-screen frame center, not `kAXPressAction` — found live
    /// while building this harness that synthetic AXPress on this app's transport buttons is
    /// occasionally a no-op (reports success but the SwiftUI action never fires, e.g. right after
    /// a previous action just changed the view), matching the same unreliability already worked
    /// around for the playlist picker's menu items. A real click is indistinguishable from what a
    /// user does, so it doesn't depend on how any particular control bridges a given AX action.
    private func click(_ element: AXUIElement, identifier: String) throws {
        guard let frame = AX.frame(element) else {
            throw HarnessError(description: "no frame for \(identifier), cannot click")
        }
        Input.click(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    func pressButton(identifier: String, in window: AXUIElement) throws {
        guard let button = find(identifier: identifier, in: window) else {
            throw HarnessError(description: "no button with identifier \(identifier)")
        }
        try click(button, identifier: identifier)
    }

    /// Selects an entry from the playlist picker by its visible title ("Rock3", "Jazz", "BGM",
    /// …). Direct `AXUIElementSetAttributeValue` on the popup button's value does *not* work for
    /// this SwiftUI `Picker` (confirmed live) — has to actually open the menu and press the
    /// matching `AXMenuItem`, with a leading Escape to guarantee no stale menu is left open from
    /// a previous interaction.
    func selectPlaylist(named name: String, in window: AXUIElement) throws {
        Input.dismissAnyOpenMenu()
        guard let picker = find(identifier: "PlaylistBar.playlistPicker", in: window) else {
            throw HarnessError(description: "no playlist picker found")
        }
        guard AX.press(picker) else {
            throw HarnessError(description: "failed to open playlist picker menu")
        }
        guard let menu = waitUntil(timeout: 2, { AX.children(picker).first }) else {
            throw HarnessError(description: "playlist picker menu never appeared")
        }
        let items = AX.children(menu)
        guard let match = items.first(where: { AX.title($0) == name }) else {
            Input.dismissAnyOpenMenu()
            throw HarnessError(description: "no picker item titled \(name) (options: \(items.map(AX.title)))")
        }
        guard AX.press(match) else {
            throw HarnessError(description: "failed to press picker item \(name)")
        }
    }

    func currentPlaylistName(in window: AXUIElement) -> String? {
        guard let picker = find(identifier: "PlaylistBar.playlistPicker", in: window) else { return nil }
        return AX.value(picker)
    }

    /// Convenience for polling loops: re-fetches whatever window is currently open (if any) and
    /// reads its picker value in one call, swallowing the "no window" case as `nil`.
    func currentPlaylistName() -> String? {
        guard let window = try? self.window() else { return nil }
        return currentPlaylistName(in: window)
    }

    /// Clicks a track-list row by its visible label (title text) — rows don't carry unique
    /// `AXIdentifier`s (SwiftUI collapses them inside this `ForEach`, see ContentView.swift), so
    /// matching by label is what actually distinguishes them.
    func clickTrackRow(labeled label: String, in window: AXUIElement) throws {
        guard let trackList = find(identifier: "PlaylistBar.trackList", in: window) else {
            throw HarnessError(description: "no track list found")
        }
        guard let row = AX.findFirst(in: trackList, role: "AXButton", label: label) else {
            throw HarnessError(description: "no track row labeled \(label)")
        }
        try click(row, identifier: "track row '\(label)'")
    }

    func playPauseLabel(in window: AXUIElement) -> String? {
        find(identifier: "PlaylistBar.playPauseButton", in: window).map(AX.label)
    }

    func errorBannerText(in window: AXUIElement) -> String? {
        find(identifier: "PlaylistBar.errorBanner", in: window).map(AX.label).flatMap { $0.isEmpty ? nil : $0 }
    }

    func ytdlpMissingBannerText(in window: AXUIElement) -> String? {
        find(identifier: "PlaylistBar.ytdlpMissingBanner", in: window).map(AX.label).flatMap { $0.isEmpty ? nil : $0 }
    }

    func trackListFrameHeight(in window: AXUIElement) -> CGFloat? {
        find(identifier: "PlaylistBar.trackList", in: window).flatMap(AX.frame)?.height
    }

    // MARK: - Screenshot

    /// Captures *only* this app's own window (`screencapture -l<windowNumber>`), never the full
    /// screen — a full-screen grab during development of this harness accidentally captured an
    /// unrelated browser window with personal email content, which is exactly the failure mode
    /// this avoids: the region is scoped by CoreGraphics window ID, not screen coordinates.
    @discardableResult
    func screenshot(to path: String) throws -> Bool {
        guard let (_, windowNumber) = currentWindowInfo() else {
            throw HarnessError(description: "no window to screenshot")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(windowNumber)", path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
