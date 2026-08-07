// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeVisualQAKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeVisualQA", targets: ["ForgeVisualQA"]),
    ],
    targets: [
        .target(name: "ForgeVisualQA"),
        .testTarget(name: "ForgeVisualQATests", dependencies: ["ForgeVisualQA"]),
    ]
)
