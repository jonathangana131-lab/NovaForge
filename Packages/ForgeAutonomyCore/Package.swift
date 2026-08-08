// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeAutonomyCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ForgeAutonomyCore", targets: ["ForgeAutonomyCore"])
    ],
    targets: [
        .target(name: "ForgeAutonomyCore"),
        .testTarget(name: "ForgeAutonomyCoreTests", dependencies: ["ForgeAutonomyCore"])
    ]
)
