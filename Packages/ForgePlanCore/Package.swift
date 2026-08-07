// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgePlanCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ForgePlanCore", targets: ["ForgePlanCore"])
    ],
    targets: [
        .target(name: "ForgePlanCore"),
        .testTarget(name: "ForgePlanCoreTests", dependencies: ["ForgePlanCore"])
    ]
)
