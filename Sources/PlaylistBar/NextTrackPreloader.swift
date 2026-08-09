import Foundation

/// Resolves the stream URL for "the track after this one" in the background while the current
/// track plays, so auto-advance (playback-controller-004) doesn't have a perceptible resolution
/// delay. Only ever tracks one pending/completed preload at a time.
@MainActor
final class NextTrackPreloader {
    private(set) var preloadedVideoID: String?
    private var preloadTask: Task<Void, Never>?
    private var resolvedURL: URL?
    private var resolvedDuration: Double?

    /// Starts (or restarts) a background preload for the track immediately after `currentIndex`
    /// in `tracks`, wrapping around to index 0 if `currentIndex` is the last track. Replaces —
    /// and cancels — any previous preload. Also kicks off loudness analysis (volume-control-006)
    /// for that track via `loudnessCoordinator` if it isn't already cached, so normal forward
    /// listening has its normalization gain ready with no added delay by the time playback gets
    /// there — fire-and-forget, this doesn't wait on that analysis the way
    /// `PlaybackController`'s out-of-order-jump path does.
    func beginPreload(
        tracks: [CachedTrack], currentIndex: Int, playlistSlug: String,
        loudnessCoordinator: LoudnessGainCoordinator
    ) {
        cancel()
        guard !tracks.isEmpty else { return }

        let nextIndex = (currentIndex + 1) % tracks.count
        let nextTrack = tracks[nextIndex]
        preloadedVideoID = nextTrack.videoID

        preloadTask = Task { [weak self] in
            let result = try? await Task.detached(priority: .utility) {
                try StreamResolver.resolve(videoID: nextTrack.videoID)
            }.value

            guard !Task.isCancelled else { return }
            guard let self, self.preloadedVideoID == nextTrack.videoID else { return }

            if case .available(let url, let duration) = result {
                self.resolvedURL = url
                self.resolvedDuration = duration
                loudnessCoordinator.beginAnalysisIfNeeded(
                    track: nextTrack, url: url, playlistSlug: playlistSlug
                )
            }
        }
    }

    /// Returns the preloaded URL (and its known real duration, see `StreamResolution`) if one is
    /// ready for `videoID`, consuming it (a fresh preload must be started for whatever comes
    /// after). Returns `nil` if there's no matching preload yet (still in flight, was for a
    /// different track, or failed) — the caller should fall back to resolving fresh in that case.
    func takePreloaded(for videoID: String) -> (url: URL, duration: Double?)? {
        guard preloadedVideoID == videoID, let url = resolvedURL else { return nil }
        let duration = resolvedDuration
        cancel()
        return (url, duration)
    }

    /// Discards any in-flight or completed preload. Call this whenever navigation moves away
    /// from the track a preload was computed for (manual prev/next/track click) before it's
    /// used, so a stale preload can't be mistakenly applied to the wrong track later.
    func cancel() {
        preloadTask?.cancel()
        preloadTask = nil
        preloadedVideoID = nil
        resolvedURL = nil
        resolvedDuration = nil
    }
}
