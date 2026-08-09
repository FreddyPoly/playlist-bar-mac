import Combine
import Foundation

/// Cache-first playlist loading: returns cached tracks immediately whenever a cache exists, and
/// only blocks the caller on a full yt-dlp scan when there's no cache at all yet. A stale
/// (>24h old, see `PlaylistCache.isStale`) cache is refreshed in the background without making
/// the caller wait, swapping in the updated track list once the refresh completes.
@MainActor
final class PlaylistLoader: ObservableObject {
    @Published private(set) var tracks: [CachedTrack] = []
    @Published private(set) var isLoading = false
    /// Set when the most recent scan attempt failed (e.g. yt-dlp missing or erroring). Cleared
    /// on the next successful scan. Used by menu-bar-ui-005 to show a distinct error message
    /// instead of the app silently appearing to hang.
    @Published private(set) var lastScanErrorMessage: String?

    /// Called whenever a scan completes and updates `tracks` — including a background
    /// stale-cache refresh that finishes well after the `load()` call that triggered it has
    /// already returned. Lets a caller (`PlaybackController`) stay in sync with results that
    /// arrive later, instead of only ever seeing a one-time snapshot from its own `load()` call.
    /// Not called for the instant cache-hit path in `load()`, since that caller already has the
    /// result synchronously as soon as `load()` returns.
    var onTracksUpdated: (([CachedTrack]) -> Void)?

    /// Tracks whichever scan is currently in flight — a cold-cache full load *or* a stale-cache
    /// background refresh — so a subsequent `load()` call for a different playlist can actually
    /// cancel it. Covers both cases (a previous version of this only tracked the background-
    /// refresh case, so switching away from a playlist mid-scan didn't stop its cold-cache scan
    /// from later overwriting `tracks`/`lastScanErrorMessage` with results for a playlist that
    /// was no longer selected).
    private var activeTask: Task<Void, Never>?

    /// Loads (or resumes) the given playlist. Safe to call again with a different playlist —
    /// any in-flight scan for a previous playlist is cancelled first.
    func load(playlistSlug: String, playlistURL: String) async {
        activeTask?.cancel()
        activeTask = nil

        if let cached = PlaylistCacheStore.load(playlistSlug: playlistSlug) {
            tracks = cached.tracks
            isLoading = false

            if cached.isStale {
                activeTask = Task { [weak self] in
                    await self?.rescanAndStore(playlistSlug: playlistSlug, playlistURL: playlistURL)
                }
            }
        } else {
            isLoading = true
            let task: Task<Void, Never> = Task { [weak self] in
                await self?.rescanAndStore(playlistSlug: playlistSlug, playlistURL: playlistURL)
            }
            activeTask = task
            await task.value
            isLoading = false
        }
    }

    /// Scans the playlist off the main actor (yt-dlp is a blocking subprocess call) and, on
    /// success, updates both the on-disk cache and the published track list. On failure, leaves
    /// the existing cache and displayed tracks untouched — a broken refresh shouldn't take away
    /// a working cache. Checks cancellation on every exit path (not just the success path) since
    /// this can be superseded by a `load()` call for a different playlist while in flight.
    private func rescanAndStore(playlistSlug: String, playlistURL: String) async {
        let scanned: [CachedTrack]
        do {
            scanned = try await Task.detached(priority: .utility) {
                try PlaylistScanner.scan(playlistURL: playlistURL)
            }.value
        } catch PlaylistScanner.ScanError.ytDlpNotFound {
            guard !Task.isCancelled else { return }
            lastScanErrorMessage = "yt-dlp not found — run `brew install yt-dlp`"
            return
        } catch {
            guard !Task.isCancelled else { return }
            lastScanErrorMessage = "Couldn't load this playlist — check your network connection."
            return
        }

        // Persist a successful scan's cache unconditionally, even if this call has since been
        // superseded by load() for a different playlist — the scan already paid its network/
        // subprocess cost, so the cache is still worth keeping for next time. Only the *live*
        // published state below (which could visibly affect whatever's currently displayed) is
        // gated on cancellation.
        let cache = PlaylistCache(tracks: scanned, lastScannedAt: Date())
        try? PlaylistCacheStore.save(cache, playlistSlug: playlistSlug)

        guard !Task.isCancelled else { return }

        lastScanErrorMessage = nil
        tracks = scanned
        onTracksUpdated?(scanned)
    }
}
