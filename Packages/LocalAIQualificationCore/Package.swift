// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalAIQualificationCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LocalAIQualificationCore", targets: ["LocalAIQualificationCore"]),
    ],
    targets: [
        .target(name: "LocalAIQualificationCore"),
        .testTarget(
            name: "LocalAIQualificationCoreTests",
            dependencies: ["LocalAIQualificationCore"]
        ),
    ]
)
