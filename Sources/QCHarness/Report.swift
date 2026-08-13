import Foundation

enum ScenarioCategory: String, Codable {
    /// End-to-end interaction with the real popover (open menu, switch playlists, click
    /// transport controls, read the track list).
    case ui
    /// Targeted replay of a specific previously-found-and-fixed bug, keyed to the issue that
    /// fixed it.
    case regression
    /// A static check of the source itself rather than a live interaction — used only where a
    /// live behavioral replay isn't practical (see each scenario's own doc comment for why).
    case codeInvariant
    /// Behavior that no longer exists in the app (superseded by a later, deliberate change) —
    /// recorded so the regression list stays a complete history, not silently tested as a pass.
    case obsolete
}

enum ScenarioStatus: String, Codable {
    case passed
    case failed
    case skipped
}

struct ScenarioResult: Codable {
    let name: String
    let category: ScenarioCategory
    let status: ScenarioStatus
    let message: String
    let durationSeconds: Double
    let screenshot: String?
    /// Issue slug(s) this scenario guards against regressing, e.g. "bgm-006". Empty for plain
    /// UI scenarios with no specific past bug attached.
    let relatedIssues: [String]
}

struct QCReport: Codable {
    let startedAt: Date
    let finishedAt: Date
    let bundleIdentifier: String
    let scenarios: [ScenarioResult]
    var summary: Summary {
        Summary(
            total: scenarios.count,
            passed: scenarios.filter { $0.status == .passed }.count,
            failed: scenarios.filter { $0.status == .failed }.count,
            skipped: scenarios.filter { $0.status == .skipped }.count
        )
    }

    struct Summary: Codable {
        let total: Int
        let passed: Int
        let failed: Int
        let skipped: Int
    }

    func write(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Re-encode with `summary` included by wrapping in a plain struct, since the computed
        // property above isn't picked up by Codable synthesis on its own.
        struct Envelope: Encodable {
            let startedAt: Date
            let finishedAt: Date
            let bundleIdentifier: String
            let summary: Summary
            let scenarios: [ScenarioResult]
        }
        let envelope = Envelope(
            startedAt: startedAt,
            finishedAt: finishedAt,
            bundleIdentifier: bundleIdentifier,
            summary: summary,
            scenarios: scenarios
        )
        let data = try encoder.encode(envelope)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
