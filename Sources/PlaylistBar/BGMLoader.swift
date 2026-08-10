import Combine
import Foundation

/// Cache-first BGM pool loading: mirrors `PlaylistLoader`'s cache-first / background-refresh-
/// when-stale pattern, but for the pooled, multi-channel BGM cache (`BGMCache.swift`) — and,
/// critically, **merges** a refresh's results into the existing pool (preserving listen counts
/// and normalization gain) rather than replacing it outright, via `BGMCacheStore.merge`. See
/// SPEC.md's "BGM channel playback" for why that merge is required (a full replace would reset
/// every video's listen count on every 24h refresh, defeating the feature).
@MainActor
final class BGMLoader: ObservableObject {
    @Published private(set) var tracks: [BGMTrack] = []
    @Published private(set) var isLoading = false
    /// Set when the most recent scan attempt failed (e.g. yt-dlp missing or erroring). Cleared on
    /// the next successful scan — same convention as `PlaylistLoader.lastScanErrorMessage`.
    @Published private(set) var lastScanErrorMessage: String?

    /// Called whenever a background refresh completes and updates `tracks`, after the `load()`
    /// call that triggered it has already returned — same convention as
    /// `PlaylistLoader.onTracksUpdated`.
    var onTracksUpdated: (([BGMTrack]) -> Void)?

    /// Tracks whichever scan is currently in flight, so a subsequent `load()` call can cancel a
    /// still-running one — same convention as `PlaylistLoader.activeTask`.
    private var activeTask: Task<Void, Never>?

    /// Loads (or resumes) the BGM pool. Safe to call again — any in-flight scan is cancelled
    /// first.
    func load() async {
        activeTask?.cancel()
        activeTask = nil

        if let cached = BGMCacheStore.load() {
            tracks = cached.tracks
            isLoading = false

            if cached.isStale {
                activeTask = Task { [weak self] in
                    await self?.rescanAndMerge()
                }
            }
        } else {
            isLoading = true
            let task: Task<Void, Never> = Task { [weak self] in
                await self?.rescanAndMerge()
            }
            activeTask = task
            await task.value
            isLoading = false
        }
    }

    /// Scans every configured channel (`BGMChannels.all`) off the main actor, merges the combined
    /// result against the existing pool by video id (`BGMCacheStore.merge`), and persists it. On
    /// failure, leaves the existing cache and displayed pool untouched — a broken refresh
    /// shouldn't take away a working pool, same as `PlaylistLoader.rescanAndStore`. Checks
    /// cancellation on every exit path since this can be superseded by a later `load()` call.
    private func rescanAndMerge() async {
        let scanned: [BGMTrack]
        do {
            scanned = try await Task.detached(priority: .utility) {
                // Scans each configured channel in turn and pools the results, deduping by video
                // id across channels (first channel to report a given id wins) — see SPEC.md's
                // pooled-not-per-channel decision.
                var pooled: [BGMTrack] = []
                var seenVideoIDs = Set<String>()
                for channelURL in BGMChannels.all {
                    for track in try BGMChannelScanner.scan(channelURL: channelURL)
                    where !seenVideoIDs.contains(track.videoID) {
                        seenVideoIDs.insert(track.videoID)
                        pooled.append(track)
                    }
                }
                return pooled
            }.value
        } catch BGMChannelScanner.ScanError.ytDlpNotFound {
            guard !Task.isCancelled else { return }
            lastScanErrorMessage = "yt-dlp not found — run `brew install yt-dlp`"
            return
        } catch {
            guard !Task.isCancelled else { return }
            lastScanErrorMessage = "Couldn't load BGM — check your network connection."
            return
        }

        // Merge against whatever's currently on disk (not the in-memory `tracks`, which could be
        // stale relative to a concurrent write) before persisting — preserves listenCount for
        // every track still eligible, per BGMCacheStore.merge's contract.
        let existingTracks = BGMCacheStore.load()?.tracks ?? []
        let merged = BGMCacheStore.merge(freshlyScanned: scanned, into: existingTracks)
        let cache = BGMPoolCache(tracks: merged, lastScannedAt: Date())
        try? BGMCacheStore.save(cache)

        guard !Task.isCancelled else { return }

        lastScanErrorMessage = nil
        tracks = merged
        onTracksUpdated?(merged)
    }
}
