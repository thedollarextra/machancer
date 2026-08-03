// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacHancer",
    platforms: [.macOS(.v14)],
    targets: [
        // All behaviour lives here so it can be unit tested; the executable is a shim.
        .target(name: "MacHancerCore", path: "Sources/MacHancerCore"),
        .executableTarget(
            name: "MacHancer",
            dependencies: ["MacHancerCore"],
            path: "Sources/MacHancer"
        ),
        // Runs without Xcode: `swift run MacHancerChecks`. The XCTest target below
        // needs a full Xcode install, which is not a given on a machine that can
        // otherwise build and run this app.
        .executableTarget(
            name: "MacHancerChecks",
            dependencies: ["MacHancerCore"],
            path: "Sources/MacHancerChecks"
        ),
        .testTarget(
            name: "MacHancerCoreTests",
            dependencies: ["MacHancerCore"],
            path: "Tests/MacHancerCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
