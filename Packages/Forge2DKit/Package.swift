// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Forge2DKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Forge2DKit", targets: ["Forge2DKit"]),
    ],
    targets: [
        .target(name: "Forge2DKit"),
        .testTarget(name: "Forge2DKitTests", dependencies: ["Forge2DKit"]),
    ]
)
