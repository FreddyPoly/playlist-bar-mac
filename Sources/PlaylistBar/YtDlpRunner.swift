import Foundation

/// Shared subprocess execution for yt-dlp, used by both playlist scanning and stream
/// resolution: resolves yt-dlp's absolute path once via `YtDlpLocator` (rather than relying on
/// PATH at invocation time, which GUI-launched apps often lack — see YtDlpAvailability.swift)
/// and runs it with a fixed argument array.
enum YtDlpRunner {
    struct Result {
        let output: String
        let errorOutput: String
        let exitCode: Int32
    }

    enum RunError: Error {
        case ytDlpNotFound
        case launchFailed(Error)
        /// `timeout` elapsed before the process finished — it has already been terminated by the
        /// time this is thrown. See `StreamResolver`'s own timeout, the caller that actually sets
        /// this for single-video resolution (playlist/channel scans pass no timeout, since a full
        /// scan legitimately takes longer and isn't part of the "stuck spinner" failure mode this
        /// exists for — see SPEC.md's "Resolution and buffering timeouts").
        case timedOut
    }

    /// Runs `yt-dlp` with `arguments`, optionally bounded by `timeout`. On timeout, the
    /// subprocess is terminated (not left running in the background) and `RunError.timedOut` is
    /// thrown — deliberately not "stop waiting but let it finish," unlike the loudness-analysis
    /// timeout elsewhere in this codebase: a stream-resolve stall is more likely a genuine hang
    /// than a merely-slow analysis, and leaving terminated subprocesses to pile up in the
    /// background across many stuck tracks would leak resources over a long session.
    /// YouTube now rejects cookie-less requests from this machine outright ("Sign in to confirm
    /// you're not a bot", even for public playlists/videos — found live 2026-09-04, see SPEC.md's
    /// "Playback engine" and Security section). Prepended to every call so scans and single-video
    /// resolution alike authenticate the same way; Brave must be installed and logged into
    /// YouTube for this to succeed, but a failure here surfaces as an ordinary yt-dlp error
    /// (unrecognized/unavailable-track handling), not a new special case.
    private static let cookieArguments = ["--cookies-from-browser", "brave"]

    static func run(arguments: [String], timeout: Duration? = nil) throws -> Result {
        guard case .available(let path) = YtDlpLocator.checkAvailability() else {
            throw RunError.ytDlpNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = cookieArguments + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(error)
        }

        // Drain both pipes concurrently, not sequentially, and not after waitUntilExit(): a
        // pipe's buffer is only ~64KB, and a large playlist's JSON output blows past that
        // easily. If we wait for the process to exit before reading, or read stdout fully
        // before touching stderr, the child can block on a full pipe forever, which blocks us
        // right back on waitUntilExit() — a classic Process/Pipe deadlock.
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutHandle.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrHandle.readDataToEndOfFile()
            group.leave()
        }

        if let timeout {
            // `group.wait(timeout:)` bounds only the pipe drains, not the process itself — a
            // process that's still running but simply hasn't produced output yet would otherwise
            // report "timed out" while still alive. Terminating it first is what actually makes
            // the drains finish promptly afterward (closing the pipes), so the unconditional
            // `group.wait()` below returns quickly rather than needing its own timeout too.
            if group.wait(timeout: .now() + timeout.timeInterval) == .timedOut {
                process.terminate()
                group.wait()
                process.waitUntilExit()
                throw RunError.timedOut
            }
        } else {
            group.wait()
        }

        process.waitUntilExit()

        return Result(
            output: String(data: stdoutData, encoding: .utf8) ?? "",
            errorOutput: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
