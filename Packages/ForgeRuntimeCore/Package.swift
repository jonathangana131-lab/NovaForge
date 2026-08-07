// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeRuntimeCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeRuntimeCore", targets: ["ForgeRuntimeCore"]),
    ],
    targets: [
        .target(name: "ForgeRuntimeCore"),
        .testTarget(
            name: "ForgeRuntimeCoreTests",
            dependencies: ["ForgeRuntimeCore"],
            resources: [.process("Fixtures")]
        ),
    ]
)
