import AVFoundation
import Combine

/// Thin wrapper around `AVPlayer` for playing a single resolved audio stream URL at a time.
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    /// True while playback is stalled/buffering — i.e. we've called `play()` but audio isn't
    /// actually advancing right now (network stall, slow/throttled stream, initial buffering).
    /// Driven off `AVPlayer.timeControlStatus` rather than a custom timer/heuristic: AVFoundation
    /// already has to solve "are we actually playing or just waiting for data" internally (that's
    /// what `automaticallyWaitsToMinimizeStalling` is for), so relaying its own signal avoids
    /// reinventing stall detection and its false-positive/jitter pitfalls.
    @Published private(set) var isBuffering = false {
        didSet { onBufferingChange?(isBuffering) }
    }

    private let player = AVPlayer()
    private var didFinishObserver: NSObjectProtocol?
    private var timeControlStatusObserver: NSKeyValueObservation?
    /// Disables any video track on the currently-loaded item once it's known (see `load()`) —
    /// there's no video surface anywhere in this `MenuBarExtra`-only app, so a video track (BGM's
    /// progressive-format streams carry one, see `StreamResolver.resolve(preferProgressive:)`)
    /// would otherwise be decoded for nothing, for as long as an hour, for no benefit.
    private var itemTracksObserver: NSKeyValueObservation?
    private var onFinish: (() -> Void)?
    private var onBufferingChange: ((Bool) -> Void)?

    /// Held for as long as we're actively playing, telling macOS not to App Nap (or idle-sleep)
    /// this process. Without it, this `LSUIElement` menu bar app — which has no visible window —
    /// is a prime App Nap target once backgrounded; a long track could in principle keep playing
    /// while the rest of our code (including did-finish handling) stops getting scheduled.
    private var backgroundActivityToken: NSObjectProtocol?

    private var knownEndWatchdog: Timer?
    private var hasFiredFinishForCurrentItem = false

    /// Attenuates this app's own audio output (0.0–1.0), independent of system/macOS volume —
    /// this is `AVPlayer`'s own `volume` property, which applies immediately to whatever's
    /// currently loaded with no restart/reload (volume-control-001).
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    /// Current elapsed playback position in seconds — exposed for callers that need to observe
    /// progress without `AudioPlayer` needing to know why (e.g. BGM's listen-count threshold, see
    /// `BGMListenTracker`/bgm-005). Backed by the same `AVPlayer` state as everything else here,
    /// not a second, competing notion of "how far into this track are we."
    var currentTime: Double {
        CMTimeGetSeconds(player.currentTime())
    }

    /// Extra time past `knownDuration` before the watchdog fires, covering yt-dlp's duration
    /// being a rounded integer and small encoder/timing discrepancies — large enough to never
    /// cut off real trailing content, tiny compared to the multi-minute delay it replaces.
    private static let knownEndGraceSeconds = 2.0

    /// Loads a new stream URL, replacing whatever was previously playing (no overlapping audio),
    /// and starts playback unless `autoplay` is false. `duration` is the track's real duration
    /// per yt-dlp (see `StreamResolution`), used as a trustworthy fallback for detecting the
    /// track's actual end.
    ///
    /// **Why this fallback exists:** `AVPlayerItemDidPlayToEndTime` alone isn't reliable for
    /// these streams. YouTube serves resolved audio as a progressively-streamed, "not optimized"
    /// (moov-atom-at-end) M4A — confirmed via `afinfo` against a fully-downloaded real file — so
    /// `AVFoundation` has to estimate duration before it's actually read enough of the file to
    /// know better, and that estimate has been confirmed (on real tracks, reproducibly) to be
    /// roughly **2x** the true duration, most likely a channel-count/bitrate misdetection —
    /// `Content-Length` itself is correct and matches the real file exactly, so this isn't a
    /// throttling/network artifact. Forcing `AVURLAssetPreferPreciseDurationAndTimingKey` does
    /// not fix it (returns the same wrong value near-instantly, without reading more data).
    /// Real playback confirmed to actually go silent once genuine content ends, with the item
    /// continuing to report `rate == 1` and advancing `currentTime` at real-time pace regardless
    /// — i.e. AVFoundation's own model believes it's still validly playing, so there's no stall
    /// signal (`isBuffering` above) to catch this either. Since yt-dlp already knows the real
    /// duration (it's the video's own metadata), this watchdog uses that instead of waiting on
    /// AVFoundation's broken one.
    /// Extra time before `duration` within which a requested `startTime` is treated as "basically
    /// the end" and clamped to 0:00 instead — otherwise a resume lands a few seconds before the
    /// trusted-duration watchdog fires and triggers a near-instant auto-advance. Internal (not
    /// `private`) so `PlaybackController` can predict the same clamp decision when deciding what
    /// position to persist as "where this track actually started" — see playback-controller-006.
    static let nearEndClampSeconds = 5.0

    func load(url: URL, duration: Double?, startTime: Double? = nil, autoplay: Bool = true) {
        removeFinishObserver()
        knownEndWatchdog?.invalidate()
        itemTracksObserver?.invalidate()
        isBuffering = false
        hasFiredFinishForCurrentItem = false

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        if let startTime, startTime > 0 {
            let isNearEnd = duration.map { startTime >= $0 - Self.nearEndClampSeconds } ?? false
            if !isNearEnd {
                player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
            }
        }

        // `item.tracks` populates asynchronously as the asset loads. A no-op for audio-only items
        // (the 4 fixed playlists) since none of their tracks are ever `.video`.
        itemTracksObserver = item.observe(\.tracks, options: [.new]) { item, _ in
            for track in item.tracks where track.assetTrack?.mediaType == .video {
                track.isEnabled = false
            }
        }

        didFinishObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fireFinish()
            }
        }

        if timeControlStatusObserver == nil {
            timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    self?.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            }
        }

        if let duration {
            let threshold = duration + Self.knownEndGraceSeconds
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isPlaying, !self.hasFiredFinishForCurrentItem else { return }
                    if CMTimeGetSeconds(self.player.currentTime()) >= threshold {
                        self.fireFinish()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            knownEndWatchdog = timer
        }

        if autoplay {
            play()
        }
    }

    func play() {
        player.play()
        isPlaying = true
        beginBackgroundActivity()
    }

    /// Seeks the currently loaded item back to 0:00 and (re)starts playback — used by BGM's Reset
    /// (bgm-008), which restarts the *current* video rather than jumping to a different one; no
    /// resolution/reload involved since the same item is already loaded. Resets
    /// `hasFiredFinishForCurrentItem` so the end-of-track watchdog/notification can fire again for
    /// this fresh lap through the same item, in the unlikely case it had already fired (a race
    /// between Reset and the item naturally ending at the same moment).
    func restart() {
        player.seek(to: .zero)
        hasFiredFinishForCurrentItem = false
        play()
    }

    func pause() {
        player.pause()
        isPlaying = false
        endBackgroundActivity()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeFinishObserver()
        knownEndWatchdog?.invalidate()
        itemTracksObserver?.invalidate()
        isPlaying = false
        isBuffering = false
        endBackgroundActivity()
    }

    /// Called when the currently loaded track finishes playing naturally (used by
    /// playback-controller-004 for auto-advance).
    func setOnFinish(_ handler: @escaping () -> Void) {
        onFinish = handler
    }

    /// Called whenever `isBuffering` changes (see its doc comment) — used by `PlaybackController`
    /// to mirror the signal for `menu-bar-ui-006` to display.
    func setOnBufferingChange(_ handler: @escaping (Bool) -> Void) {
        onBufferingChange = handler
    }

    private func fireFinish() {
        guard !hasFiredFinishForCurrentItem else { return }
        hasFiredFinishForCurrentItem = true
        isPlaying = false
        isBuffering = false
        endBackgroundActivity()
        onFinish?()
    }

    private func beginBackgroundActivity() {
        guard backgroundActivityToken == nil else { return }
        backgroundActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Playing background audio"
        )
    }

    private func endBackgroundActivity() {
        guard let token = backgroundActivityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        backgroundActivityToken = nil
    }

    private func removeFinishObserver() {
        guard let observer = didFinishObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        didFinishObserver = nil
    }

    deinit {
        if let observer = didFinishObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        knownEndWatchdog?.invalidate()
        if let token = backgroundActivityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
    }
}
