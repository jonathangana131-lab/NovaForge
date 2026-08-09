// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeAccessibilityCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeAccessibilityCore", targets: ["ForgeAccessibilityCore"]),
    ],
    targets: [
        .target(name: "ForgeAccessibilityCore"),
        .testTarget(name: "ForgeAccessibilityCoreTests", dependencies: ["ForgeAccessibilityCore"]),
    ]
)
