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
            // Deliberately an HStack of Image+Text rather than `Label(_:systemImage:)`: a
            // MenuBarExtra status item doesn't reliably render Label's title text next to its
            // icon (it collapses to icon-only), even though the icon itself shows fine.
            HStack {
                Image(systemName: "music.note")
                Text(menuBarTitle)
            }
            .task {
                await controller.restoreLastSession()
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarTitle: String {
        guard let index = controller.currentIndex, controller.tracks.indices.contains(index) else {
            return "Playlist Bar"
        }
        let title = controller.tracks[index].title
        let maxLength = 20
        guard title.count > maxLength else { return title }
        return String(title.prefix(maxLength)) + "…"
    }
}

/// MenuBarExtra alone doesn't hide the Dock icon; activation policy has to be set explicitly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
