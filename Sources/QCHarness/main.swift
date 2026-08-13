import AppKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("qcharness: \(message)\n".data(using: .utf8)!)
    exit(1)
}

struct Options {
    var bundleIdentifier = "com.studiobleumoutarde.PlaylistBar"
    var reportPath = "qc-report.json"
    var screenshotDir = "qc-screenshots"
    var sourceRoot = FileManager.default.currentDirectoryPath
    var waitTimeout: TimeInterval = 20
    var skipYtdlpOutage = false
}

func parseOptions(_ args: [String]) -> Options {
    var options = Options()
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--bundle-id":
            guard let value = iterator.next() else { fail("--bundle-id needs a value") }
            options.bundleIdentifier = value
        case "--report":
            guard let value = iterator.next() else { fail("--report needs a value") }
            options.reportPath = value
        case "--screenshot-dir":
            guard let value = iterator.next() else { fail("--screenshot-dir needs a value") }
            options.screenshotDir = value
        case "--source-root":
            guard let value = iterator.next() else { fail("--source-root needs a value") }
            options.sourceRoot = value
        case "--wait-timeout":
            guard let value = iterator.next(), let seconds = TimeInterval(value) else { fail("--wait-timeout needs a numeric value") }
            options.waitTimeout = seconds
        case "--skip-ytdlp-outage":
            options.skipYtdlpOutage = true
        default:
            fail("unknown argument: \(arg)")
        }
    }
    return options
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))

guard AXIsProcessTrusted() else {
    fail("""
    Accessibility permission not granted to this process.
    Grant it via System Settings > Privacy & Security > Accessibility, then re-run.
    (Whatever process actually launched qcharness — e.g. Terminal — needs the grant, not qcharness itself,
    unless it's being run as its own standalone signed binary.)
    """)
}

try? FileManager.default.createDirectory(atPath: options.screenshotDir, withIntermediateDirectories: true)

FileHandle.standardError.write("Waiting up to \(Int(options.waitTimeout))s for \(options.bundleIdentifier) to be ready...\n".data(using: .utf8)!)

let controller: PopoverController? = waitUntil(timeout: options.waitTimeout, interval: 0.3) {
    try? PopoverController(bundleIdentifier: options.bundleIdentifier)
}

guard let controller else {
    fail("app \(options.bundleIdentifier) never became available (not running, or AX lookup failed)")
}

let startedAt = Date()
let context = ScenarioContext(
    controller: controller,
    screenshotDir: options.screenshotDir,
    sourceRoot: options.sourceRoot,
    skipYtdlpOutage: options.skipYtdlpOutage
)
let results = runAllScenarios(context: context)
let finishedAt = Date()

let report = QCReport(
    startedAt: startedAt,
    finishedAt: finishedAt,
    bundleIdentifier: options.bundleIdentifier,
    scenarios: results
)

do {
    try report.write(to: options.reportPath)
} catch {
    fail("failed to write report to \(options.reportPath): \(error)")
}

let summary = report.summary
FileHandle.standardError.write(
    "\n\(summary.passed)/\(summary.total) passed, \(summary.failed) failed, \(summary.skipped) skipped. Report: \(options.reportPath)\n"
        .data(using: .utf8)!
)

exit(summary.failed == 0 ? 0 : 1)
