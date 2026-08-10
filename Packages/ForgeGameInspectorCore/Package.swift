// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForgeGameInspectorCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeGameInspectorCore", targets: ["ForgeGameInspectorCore"]),
    ],
    targets: [
        .target(name: "ForgeGameInspectorCore"),
        .testTarget(
            name: "ForgeGameInspectorCoreTests",
            dependencies: ["ForgeGameInspectorCore"]
        ),
    ]
)
