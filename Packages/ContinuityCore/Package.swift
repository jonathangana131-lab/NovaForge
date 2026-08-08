// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ContinuityCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ContinuityCore", targets: ["ContinuityCore"]),
    ],
    targets: [
        .target(name: "ContinuityCore"),
        .testTarget(name: "ContinuityCoreTests", dependencies: ["ContinuityCore"]),
    ]
)
