// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeGhostBuildCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeGhostBuildCore", targets: ["ForgeGhostBuildCore"]),
    ],
    targets: [
        .target(name: "ForgeGhostBuildCore"),
        .testTarget(name: "ForgeGhostBuildCoreTests", dependencies: ["ForgeGhostBuildCore"]),
    ]
)
