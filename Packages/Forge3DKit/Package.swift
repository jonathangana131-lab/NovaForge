// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Forge3DKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Forge3DKit", targets: ["Forge3DKit"]),
    ],
    targets: [
        .target(name: "Forge3DKit"),
        .testTarget(name: "Forge3DKitTests", dependencies: ["Forge3DKit"]),
    ]
)
