// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgePerformanceCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgePerformanceCore", targets: ["ForgePerformanceCore"]),
    ],
    targets: [
        .target(name: "ForgePerformanceCore"),
        .testTarget(name: "ForgePerformanceCoreTests", dependencies: ["ForgePerformanceCore"]),
    ]
)
