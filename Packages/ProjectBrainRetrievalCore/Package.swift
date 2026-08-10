// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProjectBrainRetrievalCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ProjectBrainRetrievalCore", targets: ["ProjectBrainRetrievalCore"]),
    ],
    targets: [
        .target(name: "ProjectBrainRetrievalCore"),
        .testTarget(name: "ProjectBrainRetrievalCoreTests", dependencies: ["ProjectBrainRetrievalCore"]),
    ]
)
