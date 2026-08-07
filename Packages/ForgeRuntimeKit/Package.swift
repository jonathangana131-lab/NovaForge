// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeRuntimeKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeRuntime", targets: ["ForgeRuntime"]),
    ],
    targets: [
        .target(name: "ForgeRuntime"),
        .testTarget(
            name: "ForgeRuntimeTests",
            dependencies: ["ForgeRuntime"]
        ),
    ]
)
