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
    }

    static func run(arguments: [String]) throws -> Result {
        guard case .available(let path) = YtDlpLocator.checkAvailability() else {
            throw RunError.ytDlpNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

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
        group.wait()

        process.waitUntilExit()

        return Result(
            output: String(data: stdoutData, encoding: .utf8) ?? "",
            errorOutput: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }
}
