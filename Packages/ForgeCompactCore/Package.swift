// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeCompactCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ForgeCompactCore", targets: ["ForgeCompactCore"])
    ],
    targets: [
        .target(name: "ForgeCompactCore"),
        .testTarget(name: "ForgeCompactCoreTests", dependencies: ["ForgeCompactCore"])
    ]
)
