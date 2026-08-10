// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PreviewReasoningCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PreviewReasoningCore",
            targets: ["PreviewReasoningCore"]
        ),
    ],
    targets: [
        .target(name: "PreviewReasoningCore"),
        .testTarget(
            name: "PreviewReasoningCoreTests",
            dependencies: ["PreviewReasoningCore"]
        ),
    ]
)
