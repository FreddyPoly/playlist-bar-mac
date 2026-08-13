import ApplicationServices
import CoreGraphics
import Foundation

/// Thin wrappers over the raw AXUIElement C API — every other file in this target reads/writes
/// the accessibility tree only through these, so the CFTypeRef bridging lives in exactly one
/// place. Requires Accessibility permission (System Settings > Privacy & Security >
/// Accessibility) granted to whatever process runs this binary.
enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else { return nil }
        return value as? T
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    static func role(_ element: AXUIElement) -> String {
        attribute(element, kAXRoleAttribute) ?? ""
    }

    static func identifier(_ element: AXUIElement) -> String {
        attribute(element, "AXIdentifier") ?? ""
    }

    static func title(_ element: AXUIElement) -> String {
        attribute(element, kAXTitleAttribute) ?? ""
    }

    /// SwiftUI's `.accessibilityLabel` bridges to `kAXDescriptionAttribute`, not `kAXTitleAttribute`
    /// — confirmed empirically while building this harness (see PlaylistBar's own accessibility
    /// modifiers in ContentView.swift/PlaylistBarApp.swift).
    static func label(_ element: AXUIElement) -> String {
        attribute(element, kAXDescriptionAttribute) ?? ""
    }

    /// Covers both string values (`.accessibilityValue` on most controls) and numeric ones
    /// (sliders, checkboxes) by trying string first, falling back to a formatted double.
    static func value(_ element: AXUIElement) -> String {
        if let s: String = attribute(element, kAXValueAttribute), !s.isEmpty { return s }
        if let n: Double = attribute(element, kAXValueAttribute) { return String(n) }
        return ""
    }

    static func doubleValue(_ element: AXUIElement) -> Double? {
        attribute(element, kAXValueAttribute)
    }

    static func isEnabled(_ element: AXUIElement) -> Bool {
        attribute(element, kAXEnabledAttribute) ?? true
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef, CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue((posValue as! AXValue), .cgPoint, &point)
        // swiftlint:disable:next force_cast
        AXValueGetValue((sizeValue as! AXValue), .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Depth-first search of the whole subtree. `identifier`/`role`/`label` filters are AND'ed
    /// together when more than one is given; all are optional. Pre-order (root, then each child's
    /// own subtree left-to-right) — this must preserve sibling order, since callers rely on it
    /// matching visual top-to-bottom order (e.g. matching track-list rows to playlist index).
    /// An earlier version used a `popLast()` stack, which processes each level's children in
    /// *reverse*, silently flipping row order — found live via a scenario whose assertion
    /// actually depended on row order (`10-transport-previous-and-reset`), where it looked
    /// exactly like an app bug (Reset landing on the last track) until traced back here.
    static func findAll(
        in root: AXUIElement,
        identifier: String? = nil,
        role: String? = nil,
        label: String? = nil
    ) -> [AXUIElement] {
        var results: [AXUIElement] = []
        func visit(_ el: AXUIElement) {
            let idMatch = identifier == nil || AX.identifier(el) == identifier
            let roleMatch = role == nil || AX.role(el) == role
            let labelMatch = label == nil || AX.label(el) == label
            if idMatch && roleMatch && labelMatch { results.append(el) }
            for child in children(el) { visit(child) }
        }
        visit(root)
        return results
    }

    static func findFirst(
        in root: AXUIElement,
        identifier: String? = nil,
        role: String? = nil,
        label: String? = nil
    ) -> AXUIElement? {
        findAll(in: root, identifier: identifier, role: role, label: label).first
    }
}

/// Real HID-level input, used where AX's synthetic `kAXPressAction` proved unreliable against
/// this app's SwiftUI popup button (see the picker-menu handling in `PopoverController`) — a
/// genuine mouse/keyboard event is indistinguishable from what a real user does, so it doesn't
/// depend on how any particular SwiftUI control happens to bridge a given AX action.
enum Input {
    static func click(at point: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(50_000)
        up?.post(tap: .cghidEventTap)
        usleep(50_000)
    }

    private static let escapeKeyCode: CGKeyCode = 53

    /// Dismisses any stray open menu — necessary before opening the playlist picker's menu:
    /// found live while building this harness that a menu left open by a previous run/attempt
    /// silently swallows the next `kAXPressAction` on the same popup button (it just toggles the
    /// stale menu closed instead of opening a fresh one), so every picker interaction resets
    /// first rather than assuming a clean starting state.
    static func dismissAnyOpenMenu() {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: escapeKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: escapeKeyCode, keyDown: false)
        down?.post(tap: .cghidEventTap)
        usleep(50_000)
        up?.post(tap: .cghidEventTap)
        usleep(200_000)
    }
}

/// Polls `condition` every `interval` until it returns non-nil or `timeout` elapses.
@discardableResult
func waitUntil<T>(timeout: TimeInterval, interval: TimeInterval = 0.1, _ condition: () -> T?) -> T? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let value = condition() { return value }
        Thread.sleep(forTimeInterval: interval)
    }
    return condition()
}
