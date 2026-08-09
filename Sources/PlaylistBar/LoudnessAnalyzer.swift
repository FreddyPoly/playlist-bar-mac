import Foundation

enum LoudnessAnalysisError: Error {
    case ffmpegNotFound
    case processFailed(exitCode: Int32, errorOutput: String)
    case invalidOutput
}

/// Measures a track's integrated loudness via `ffmpeg`'s `loudnorm` filter (analysis-only — a
/// single read-through decode pass over the resolved stream, no output file written) and
/// converts it into a cut-only gain for `AudioPlayer.volume`. See SPEC.md's "Volume & loudness
/// normalization".
enum LoudnessAnalyzer {
    /// Cut-only normalization target — matches Spotify/YouTube Music's own normalization target.
    /// A track measured louder than this is attenuated down to it; a quieter track is left
    /// alone. `AVPlayer.volume` can't boost a track above its original loudness (0.0–1.0 range),
    /// and the whole point of this feature was reducing headroom pain, not adding volume.
    static let targetLUFS = -14.0

    /// Measures `url`'s integrated loudness and returns a gain in `0.0...1.0` — `1.0` if the
    /// track is already at or quieter than `targetLUFS`, otherwise the attenuation needed to
    /// bring it down to that target. Throws (never hangs indefinitely on its own, though a slow
    /// stream can still make this take a while — see `volume-control-007` for the bounded-wait
    /// wrapper) on a missing `ffmpeg`, an unreachable/malformed stream, or unparseable output.
    static func measureGain(url: URL) throws -> Double {
        guard case .available(let ffmpegPath) = FfmpegLocator.checkAvailability() else {
            throw LoudnessAnalysisError.ffmpegNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        // `loudnorm` alone (no output write — `-f null -`) does a single decode pass over the
        // whole input and reports the measured integrated loudness in a JSON summary — printed
        // to stderr, not stdout, which is ffmpeg's own convention for filter/progress output.
        // Passed as a plain argument array (no shell involved), so the stream URL's query string
        // (`&`, `=`, etc.) can't be interpreted as shell syntax even though it isn't
        // attacker-controlled here.
        process.arguments = [
            "-hide_banner", "-nostats", "-i", url.absoluteString,
            "-af", "loudnorm=print_format=json", "-f", "null", "-",
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw LoudnessAnalysisError.processFailed(exitCode: -1, errorOutput: "\(error)")
        }

        // Same concurrent-drain pattern as `YtDlpRunner`: reading sequentially, or only after
        // `waitUntilExit()`, risks a pipe-buffer deadlock once ffmpeg's own log output exceeds
        // the pipe's ~64KB buffer.
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = stdoutHandle.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrHandle.readDataToEndOfFile()
            group.leave()
        }
        group.wait()

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(data: stderrData, encoding: .utf8) ?? ""
            throw LoudnessAnalysisError.processFailed(
                exitCode: process.terminationStatus, errorOutput: errorOutput
            )
        }

        guard let measuredLUFS = parseMeasuredIntegratedLoudness(from: stderrData) else {
            throw LoudnessAnalysisError.invalidOutput
        }

        return gain(forMeasuredLUFS: measuredLUFS)
    }

    /// `loudnorm`'s JSON report is the last `{...}` block in stderr, mixed in among ffmpeg's own
    /// human-readable log lines — found by locating the last brace pair rather than assuming a
    /// fixed line count or position.
    static func parseMeasuredIntegratedLoudness(from stderrData: Data) -> Double? {
        guard let text = String(data: stderrData, encoding: .utf8),
              let openBrace = text.lastIndex(of: "{"),
              let closeBrace = text[openBrace...].lastIndex(of: "}") else {
            return nil
        }
        let jsonText = String(text[openBrace...closeBrace])
        guard let jsonData = jsonText.data(using: .utf8),
              let report = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let inputIString = report["input_i"] as? String,
              let inputI = Double(inputIString) else {
            return nil
        }
        return inputI
    }

    /// Cut-only: never returns more than `1.0` (never boosts a track above its original
    /// loudness).
    static func gain(forMeasuredLUFS measuredLUFS: Double) -> Double {
        guard measuredLUFS.isFinite, measuredLUFS > targetLUFS else { return 1.0 }
        let linear = pow(10, (targetLUFS - measuredLUFS) / 20)
        return min(1.0, linear)
    }
}
