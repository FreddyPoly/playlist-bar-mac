import Foundation

enum YtDlpAvailability: Equatable {
    case available(path: String)
    case unavailable
}

enum YtDlpLocator {
    /// Homebrew's bin directories. GUI/login-item-launched apps get the system default PATH
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), not an interactive shell's PATH, so Homebrew installs
    /// (which is how SPEC.md has the user install yt-dlp) wouldn't otherwise be found once this
    /// app isn't run via `swift run` from a terminal.
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

    /// Checks whether `yt-dlp` is resolvable on PATH (augmented with common Homebrew locations).
    /// Uses a fixed, non-dynamic command — no user-controlled input is ever involved in this
    /// check.
    static func checkAvailability() -> YtDlpAvailability {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "yt-dlp"]
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
