// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgePhysicsPlaygroundCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgePhysicsPlaygroundCore", targets: ["ForgePhysicsPlaygroundCore"]),
    ],
    targets: [
        .target(name: "ForgePhysicsPlaygroundCore"),
        .testTarget(
            name: "ForgePhysicsPlaygroundCoreTests",
            dependencies: ["ForgePhysicsPlaygroundCore"]
        ),
    ]
)
