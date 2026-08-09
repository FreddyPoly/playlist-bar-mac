import Foundation

/// Coordinates measuring, caching, and looking up per-track loudness normalization gain (see
/// `LoudnessAnalyzer`) so at most one analysis runs per track at a time, and a caller that stops
/// waiting on it (timeout) never cancels the analysis itself — it keeps running in the
/// background so the result still gets cached for next time. Shared by `NextTrackPreloader`
/// (volume-control-006's opportunistic head start) and `PlaybackController`'s out-of-order-jump
/// bounded wait (volume-control-007) — SPEC.md's "Volume & loudness normalization" describes
/// both as sharing one fallback path, which is what this type exists to make possible.
@MainActor
final class LoudnessGainCoordinator {
    /// Called whenever a track's gain becomes newly known from a real measurement (not a
    /// timeout/failure fallback, and not an already-cached hit) — lets `PlaybackController`
    /// update its in-memory `tracks` array even if nothing is currently waiting on this specific
    /// track (e.g. it was only ever a background preload target).
    var onGainMeasured: ((_ videoID: String, _ gain: Double) -> Void)?

    private var inFlightTasks: [String: Task<Double?, Never>] = [:]

    /// Starts analysis for `track` in the background if it isn't already cached or already in
    /// flight, without waiting for it. Used for the preload case (volume-control-006) — fires and
    /// forgets, since the whole point is not to add delay to the preload itself.
    func beginAnalysisIfNeeded(track: CachedTrack, url: URL, playlistSlug: String) {
        guard track.normalizationGain == nil, inFlightTasks[track.videoID] == nil else { return }
        inFlightTasks[track.videoID] = makeAnalysisTask(
            videoID: track.videoID, url: url, playlistSlug: playlistSlug
        )
    }

    /// Returns `track`'s gain, waiting up to `timeout` for an already-cached value, an in-flight
    /// analysis, or a freshly-started one. Returns `1.0` (unnormalized) on timeout or failure —
    /// this is a fallback for *this call*, not a measurement, so it's never written back to the
    /// cache; the analysis, if it was still running, is **not** cancelled and keeps going in the
    /// background so a later call (or `onGainMeasured`) can still pick up the real result.
    func gain(for track: CachedTrack, url: URL, playlistSlug: String, timeout: Duration) async -> Double {
        if let cached = track.normalizationGain { return cached }

        let task = inFlightTasks[track.videoID] ?? makeAnalysisTask(
            videoID: track.videoID, url: url, playlistSlug: playlistSlug
        )
        inFlightTasks[track.videoID] = task

        // Deliberately *not* `withTaskGroup` here: a task group structurally waits for every
        // child task to finish before it returns control to its caller — even a "loser" branch
        // that's already been signalled via `cancelAll()`, since cancelling the group's wrapping
        // child task doesn't cancel `task` itself (an independent, externally-stored `Task`, not
        // part of this group's structured hierarchy — `await task.value` doesn't observe that
        // cancellation at all). That made the timeout illusory in practice: this call wouldn't
        // actually return until the real analysis finished, however long that took, which is
        // exactly the "stuck forever" bug found live during volume-control QC (confirmed via a
        // standalone timing script before writing this fix — see volume-control-007's Notes).
        // A raw continuation race avoids the problem entirely: whichever side resumes first wins,
        // and the loser — still just `task` running independently — keeps going in the
        // background untouched.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Double, Never>) in
            var hasResumed = false

            Task {
                let value = await task.value
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(returning: value ?? 1.0)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(returning: 1.0)
                }
            }
        }
    }

    private func makeAnalysisTask(videoID: String, url: URL, playlistSlug: String) -> Task<Double?, Never> {
        Task { [weak self] in
            defer { self?.inFlightTasks[videoID] = nil }
            let measured = try? await Task.detached(priority: .utility) {
                try LoudnessAnalyzer.measureGain(url: url)
            }.value
            guard let measured else { return nil }
            PlaylistCacheStore.setNormalizationGain(measured, forVideoID: videoID, playlistSlug: playlistSlug)
            self?.onGainMeasured?(videoID, measured)
            return measured
        }
    }
}
