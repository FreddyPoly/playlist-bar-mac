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
    func load(url: URL, duration: Double?, autoplay: Bool = true) {
        removeFinishObserver()
        knownEndWatchdog?.invalidate()
        isBuffering = false
        hasFiredFinishForCurrentItem = false

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

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
