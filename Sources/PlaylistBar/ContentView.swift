import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: PlaybackController
    @StateObject private var loginItemManager = LoginItemManager()
    @State private var ytDlpAvailability: YtDlpAvailability?
    /// Debounced view of `isWaiting` (see below) — only flips to `true` after `isWaiting` has
    /// held continuously for `loadingIndicatorDelay`, so a fast cache-hit switch or quick stream
    /// resolve doesn't visibly flicker a loading state in and out.
    @State private var showLoadingIndicator = false
    private static let loadingIndicatorDelay: Duration = .milliseconds(300)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playlist Bar")
                .font(.headline)

            // A missing yt-dlp is also what causes `controller.errorMessage` to end up set to a
            // yt-dlp-not-found message (play() surfaces the same underlying condition) — showing
            // both at once would just duplicate the same guidance twice, so this check takes
            // priority and controller.errorMessage only renders when it isn't already covered.
            if case .unavailable = ytDlpAvailability {
                Text("yt-dlp not found — run `brew install yt-dlp`, then relaunch.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Playlist", selection: playlistSelection) {
                Text("Select a playlist").tag(Playlist?.none)
                ForEach(FixedPlaylists.all) { playlist in
                    Text(playlist.name).tag(Optional(playlist))
                }
            }
            .labelsHidden()

            HStack(spacing: 16) {
                Button {
                    Task { await controller.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                }
                .disabled(controller.currentIndex == nil)

                Button {
                    Task { await controller.togglePlayPause() }
                } label: {
                    // Distinct from both the play and pause icons — a stalled/loading track
                    // shouldn't look identical to ordinary steady-state playback (menu-bar-ui-006).
                    if showLoadingIndicator {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .disabled(controller.currentIndex == nil)

                Button {
                    Task { await controller.next() }
                } label: {
                    Image(systemName: "forward.fill")
                }
                .disabled(controller.currentIndex == nil)

                Button {
                    Task { await controller.reset() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .disabled(controller.currentIndex == nil)
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(value: volumeBinding, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(displayedTracks) { item in
                        Button {
                            Task { await controller.selectTrack(at: item.index) }
                        } label: {
                            Text(item.track.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .fontWeight(item.index == controller.currentIndex ? .semibold : .regular)
                                .foregroundStyle(
                                    item.index == controller.currentIndex ? Color.accentColor : Color.primary
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // minHeight is required, not just maxHeight: a ScrollView given only a max height
            // inside MenuBarExtra's auto-sizing window can resolve its ideal height to ~0 even
            // with real content inside it, collapsing the whole list to an invisible sliver.
            // 130 was tuned to show ~4 rows at a glance before scrolling.
            .frame(minHeight: 130, maxHeight: 220)

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { loginItemManager.isEnabled },
                set: { loginItemManager.setEnabled($0) }
            ))

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 280)
        .task {
            // Off the main thread: this spawns and waits on a subprocess (see
            // YtDlpAvailability.swift's own note on this).
            ytDlpAvailability = await Task.detached(priority: .utility) {
                YtDlpLocator.checkAvailability()
            }.value
        }
        .onAppear {
            // Login Items can change outside this app (e.g. directly in System Settings), so
            // re-sync from actual system state whenever the dropdown is shown rather than
            // trusting whatever was last set in-app.
            loginItemManager.refresh()
        }
        // Re-runs (cancelling any prior instance) whenever `isWaiting` changes, which is what
        // gives this its debounce: a wait shorter than the delay never reaches the `sleep`'s end
        // before being cancelled, so `showLoadingIndicator` only ever flips true for a wait
        // that's actually still ongoing after the delay. Flipping back to false happens
        // immediately (no delay) once the wait ends, in either branch below.
        .task(id: isWaiting) {
            if isWaiting {
                try? await Task.sleep(for: Self.loadingIndicatorDelay)
                guard !Task.isCancelled else { return }
                showLoadingIndicator = true
            } else {
                showLoadingIndicator = false
            }
        }
    }

    /// Any wait moment menu-bar-ui-006 (and volume-control-008) covers: a playlist-switch cache
    /// scan, a fresh track's stream still resolving, a mid-stream stall/buffer recovery, or an
    /// out-of-order jump waiting (boundedly) on loudness analysis.
    private var isWaiting: Bool {
        controller.isLoading || controller.isResolvingTrack || controller.isBuffering
            || controller.isAwaitingLoudnessAnalysis
    }

    /// Selecting a playlist triggers the actual switch (which has real side effects: stopping
    /// current playback, loading, resolving, persisting) rather than just storing a value, so
    /// this can't be a direct `$controller.currentPlaylist` binding — `currentPlaylist` is
    /// intentionally read-only from outside `PlaybackController`.
    private var playlistSelection: Binding<Playlist?> {
        Binding(
            get: { controller.currentPlaylist },
            set: { newValue in
                guard let newValue else { return }
                Task { await controller.switchTo(playlist: newValue) }
            }
        )
    }

    /// `Slider`'s own drag gesture already updates this binding continuously (not just on
    /// release), which is what gives the volume change its real-time feel.
    private var volumeBinding: Binding<Double> {
        Binding(
            get: { controller.masterVolume },
            set: { controller.setMasterVolume($0) }
        )
    }

    private struct DisplayedTrack: Identifiable {
        let index: Int
        let track: CachedTrack
        var id: Int { index }
    }

    /// The current track plus up to 5 previous and up to 5 next, by playlist index — not
    /// wrapped at the playlist's ends (wrap-around only applies to Previous/Next button
    /// behavior, per SPEC.md, not to what's shown here).
    private var displayedTracks: [DisplayedTrack] {
        guard let current = controller.currentIndex, !controller.tracks.isEmpty else { return [] }
        let lower = max(0, current - 5)
        let upper = min(controller.tracks.count - 1, current + 5)
        guard lower <= upper else { return [] }
        return (lower...upper).map { DisplayedTrack(index: $0, track: controller.tracks[$0]) }
    }
}
