// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PlaylistBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PlaylistBar",
            path: "Sources/PlaylistBar"
        ),
        // Automated QC harness (Scripts/qc.sh) — drives the packaged .app from the outside via
        // the Accessibility (AXUIElement) API rather than XCUITest: this is a Swift Package, not
        // an Xcode project, and SPM has no UI-test-bundle target type that can host
        // `XCUIApplication` against an external app. See SPEC.md's "Automated QC harness".
        .executableTarget(
            name: "QCHarness",
            path: "Sources/QCHarness"
        )
    ]
)
