import SwiftUI

@main
struct PlaylistBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Owned here (not in `ContentView`) so the menu bar label and the dropdown both observe
    /// the same instance — otherwise switching playlists in the dropdown would never be
    /// reflected in the menu bar title.
    @StateObject private var controller = PlaybackController()

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: controller)
        } label: {
            // The label (unlike the dropdown content) is instantiated immediately at launch,
            // which is what makes this the right place to restore the previous session —
            // ContentView's own `.task` only runs once the dropdown is actually opened.
            //
            // Icon-only, no text (changed 2026-08-12, see SPEC.md's "UI (menu bar dropdown)"):
            // a variable-width text label was the likely reason this item, specifically, kept
            // getting squeezed out of a crowded menu bar. The glyph itself swaps for play/pause
            // state as a zero-width way to keep some status visible; the track title itself is
            // dropdown-only now — a `.help()` tooltip was tried but doesn't actually render on
            // MenuBarExtra status items (the label is hosted specially by AppKit and doesn't wire
            // up SwiftUI's tooltip mechanism; same root cause as the existing Label-text-collapse
            // note below). Fixing that would mean replacing MenuBarExtra with a hand-rolled
            // NSStatusItem — not worth it for a hover tooltip; user decision via `/interview`,
            // 2026-08-12.
            Image(systemName: controller.isPlaying ? "music.note" : "pause.circle")
                // Lets an AX-based automation harness (Scripts/qc.sh's QCHarness) read
                // play/pause state directly off the status item without opening the popover,
                // and gives the status item itself a stable identifier to find among any other
                // app's menu bar extras.
                .accessibilityIdentifier("PlaylistBar.menuBarIcon")
                .accessibilityLabel(controller.isPlaying ? "Playing" : "Paused")
                .task {
                    await controller.restoreLastSession()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

/// MenuBarExtra alone doesn't hide the Dock icon; activation policy has to be set explicitly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
