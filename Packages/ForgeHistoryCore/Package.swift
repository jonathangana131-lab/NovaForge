// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeHistoryCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeHistoryCore", targets: ["ForgeHistoryCore"]),
    ],
    targets: [
        .target(name: "ForgeHistoryCore"),
        .testTarget(name: "ForgeHistoryCoreTests", dependencies: ["ForgeHistoryCore"]),
    ]
)
