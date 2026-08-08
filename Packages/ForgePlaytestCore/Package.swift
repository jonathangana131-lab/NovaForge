// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgePlaytestCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgePlaytestCore", targets: ["ForgePlaytestCore"]),
    ],
    targets: [
        .target(name: "ForgePlaytestCore"),
        .testTarget(name: "ForgePlaytestCoreTests", dependencies: ["ForgePlaytestCore"]),
    ]
)
