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
    dependencies: [
        .package(path: "../ForgePlanCore")
    ],
    targets: [
        .target(
            name: "ForgeAutonomyCore",
            dependencies: [
                .product(name: "ForgePlanCore", package: "ForgePlanCore")
            ]
        ),
        .testTarget(
            name: "ForgeAutonomyCoreTests",
            dependencies: ["ForgeAutonomyCore", "ForgePlanCore"]
        )
    ]
)
