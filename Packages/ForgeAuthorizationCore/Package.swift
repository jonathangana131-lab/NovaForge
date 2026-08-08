// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeAuthorizationCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ForgeAuthorizationCore", targets: ["ForgeAuthorizationCore"])
    ],
    dependencies: [
        .package(path: "../ForgePlanCore")
    ],
    targets: [
        .target(
            name: "ForgeAuthorizationCore",
            dependencies: [
                .product(name: "ForgePlanCore", package: "ForgePlanCore")
            ]
        ),
        .testTarget(
            name: "ForgeAuthorizationCoreTests",
            dependencies: ["ForgeAuthorizationCore", "ForgePlanCore"]
        )
    ]
)
