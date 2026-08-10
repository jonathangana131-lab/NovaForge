// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeHomeCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeHomeCore", targets: ["ForgeHomeCore"]),
    ],
    targets: [
        .target(name: "ForgeHomeCore"),
        .testTarget(name: "ForgeHomeCoreTests", dependencies: ["ForgeHomeCore"]),
    ]
)
