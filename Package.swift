// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swiftusage",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "swiftusage", targets: ["UsageGraphs"]),
    ],
    dependencies: [
        // The anonymous daily statistics and crash reports (Telemetry.swift).
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.92.4"),
    ],
    targets: [
        // zstd's decoder (1.5.7, BSD license), for Codex's compressed rollouts. The x86-64 assembly isn't
        // included, so the C loops it speeds up are used on Intel.
        .target(
            name: "CZstd",
            exclude: ["LICENSE"],
            cSettings: [.define("ZSTD_DISABLE_ASM"), .define("ZSTD_LEGACY_SUPPORT", to: "0")]
        ),
        .target(name: "UsageCore", dependencies: ["CZstd"]),
        .executableTarget(
            name: "UsageGraphs",
            dependencies: ["UsageCore", .product(name: "PostHog", package: "posthog-ios")]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"]
        ),
        .testTarget(
            name: "UsageGraphsTests",
            dependencies: ["UsageGraphs"]
        ),
    ]
)
