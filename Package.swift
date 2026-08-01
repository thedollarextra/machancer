// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MouseEnhancer",
    platforms: [.macOS(.v14)],
    targets: [
        // All behaviour lives here so it can be unit tested; the executable is a shim.
        .target(name: "MouseEnhancerCore", path: "Sources/MouseEnhancerCore"),
        .executableTarget(
            name: "MouseEnhancer",
            dependencies: ["MouseEnhancerCore"],
            path: "Sources/MouseEnhancer"
        ),
        // Runs without Xcode: `swift run MouseEnhancerChecks`. The XCTest target below
        // needs a full Xcode install, which is not a given on a machine that can
        // otherwise build and run this app.
        .executableTarget(
            name: "MouseEnhancerChecks",
            dependencies: ["MouseEnhancerCore"],
            path: "Sources/MouseEnhancerChecks"
        ),
        .testTarget(
            name: "MouseEnhancerCoreTests",
            dependencies: ["MouseEnhancerCore"],
            path: "Tests/MouseEnhancerCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
