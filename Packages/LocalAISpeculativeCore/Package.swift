// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalAISpeculativeCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LocalAISpeculativeCore", targets: ["LocalAISpeculativeCore"]),
    ],
    targets: [
        .target(name: "LocalAISpeculativeCore"),
        .testTarget(
            name: "LocalAISpeculativeCoreTests",
            dependencies: ["LocalAISpeculativeCore"]
        ),
    ]
)
