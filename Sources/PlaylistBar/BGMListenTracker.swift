import Foundation

/// Tracks whether the currently-playing BGM video has been listened to long enough to count as a
/// local "listen" — see SPEC.md's "BGM channel playback": once continuous playback passes
/// `min(30s, 20% of duration)`, increments its local listen count exactly once via
/// `BGMCacheStore.incrementListenCount(forVideoID:)`, then stops polling on its own.
///
/// Only tracks progress forward from a `start()` call — a play abandoned before the threshold
/// (skipped, playlist switched away, app quit) never increments, since nothing fires until the
/// threshold is actually reached. Callers **must** call `cancel()` when leaving BGM for another
/// playlist (not just when starting a new BGM video — `start()` already cancels any previous
/// polling itself) — otherwise a stale tracker would keep polling `currentTime()` against
/// whatever's now loaded in the player and could misattribute a listen to the wrong video. Wiring
/// that into actual playback transitions is `bgm-006`'s job, not this type's.
@MainActor
final class BGMListenTracker {
    /// `min(30s, 20% of duration)` — given the BGM pool's 15-minute floor, this is effectively
    /// always 30s in practice, but the formula (not a hardcoded 30) is what SPEC.md specifies.
    static func threshold(forDuration duration: Double) -> Double {
        min(30, duration * 0.2)
    }

    private var timer: Timer?

    /// Arms tracking for `videoID` (whose duration is `duration`), polling `currentTime()`
    /// roughly once a second. Cancels any tracking already in progress first (a new `start()`
    /// implicitly abandons whatever was being tracked before, without incrementing it).
    ///
    /// Measures the threshold relative to *elapsed playback since this `start()` call*, not
    /// `currentTime()`'s absolute value (bgm-012/bgm-013) — a video resumed already past the
    /// absolute threshold (e.g. at 25:00 of a 30:00 video) must still require a real
    /// `min(30s, 20%)` of playback from wherever it resumed before counting as a listen, exactly
    /// like starting from 0:00 does. `startPosition` (default `0`, unaffected for every existing
    /// from-the-beginning call site) is the caller's own *requested* start position, not read back
    /// from `currentTime()` at this call — `AVPlayer.seek(to:)` is asynchronous, so `currentTime()`
    /// generally still reads stale/zero for a split second right after `load()`/`seek()` return,
    /// which would silently defeat this fix by capturing the wrong baseline.
    func start(
        videoID: String, duration: Double, startPosition: Double = 0, currentTime: @escaping () -> Double
    ) {
        cancel()
        let requiredSeconds = Self.threshold(forDuration: duration)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            // Same MainActor-hop convention as AudioPlayer's own watchdog timer (`load(url:
            // duration:autoplay:)`) — a Timer callback isn't itself actor-isolated even though
            // scheduled on RunLoop.main, so hop explicitly rather than calling isolated members
            // directly from this synchronous context.
            Task { @MainActor [weak self] in
                guard currentTime() - startPosition >= requiredSeconds else { return }
                BGMCacheStore.incrementListenCount(forVideoID: videoID)
                self?.cancel()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops tracking without incrementing.
    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}
