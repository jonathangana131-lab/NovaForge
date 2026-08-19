// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalModelQualificationCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LocalModelQualificationCore", targets: ["LocalModelQualificationCore"]),
    ],
    targets: [
        .target(name: "LocalModelQualificationCore"),
        .testTarget(name: "LocalModelQualificationCoreTests", dependencies: ["LocalModelQualificationCore"]),
    ]
)
