import Foundation

enum FfmpegAvailability: Equatable {
    case available(path: String)
    case unavailable
}

/// Mirrors `YtDlpLocator` exactly, for `ffmpeg` (see `LoudnessAnalyzer`) — same rationale: GUI/
/// login-item-launched apps get the system default PATH, not an interactive shell's, so a
/// Homebrew-installed `ffmpeg` wouldn't otherwise be found once this app isn't run via
/// `swift run` from a terminal.
enum FfmpegLocator {
    private static let supplementalPathComponents = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    private static func searchPath() -> String {
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var seen = Set<String>()
        return (supplementalPathComponents + inherited)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// Checks whether `ffmpeg` is resolvable on PATH (augmented with common Homebrew locations).
    static func checkAvailability() -> FfmpegAvailability {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "ffmpeg"]
        process.environment = ["PATH": searchPath()]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .unavailable
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return .unavailable
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return .unavailable
        }

        return .available(path: path)
    }
}
