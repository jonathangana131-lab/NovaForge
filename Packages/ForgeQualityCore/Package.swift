// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeQualityCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeQualityCore", targets: ["ForgeQualityCore"]),
    ],
    targets: [
        .target(name: "ForgeQualityCore"),
        .testTarget(
            name: "ForgeQualityCoreTests",
            dependencies: ["ForgeQualityCore"]
        ),
    ]
)
