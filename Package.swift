// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swiftusage",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "swiftusage", targets: ["UsageGraphs"]),
    ],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(
            name: "UsageGraphs",
            dependencies: ["UsageCore"]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"]
        ),
    ]
)
