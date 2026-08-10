// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeEffortCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeEffortCore", targets: ["ForgeEffortCore"]),
    ],
    targets: [
        .target(name: "ForgeEffortCore"),
        .testTarget(name: "ForgeEffortCoreTests", dependencies: ["ForgeEffortCore"]),
    ]
)
