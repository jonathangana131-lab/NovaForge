// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalAIBenchmarkCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "LocalAIBenchmarkCore",
            targets: ["LocalAIBenchmarkCore"]
        ),
    ],
    targets: [
        .target(name: "LocalAIBenchmarkCore"),
        .testTarget(
            name: "LocalAIBenchmarkCoreTests",
            dependencies: ["LocalAIBenchmarkCore"]
        ),
    ]
)
