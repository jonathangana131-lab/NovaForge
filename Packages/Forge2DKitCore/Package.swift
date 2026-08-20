// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Forge2DKitCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "Forge2DKitCore", targets: ["Forge2DKitCore"])
    ],
    targets: [
        .target(name: "Forge2DKitCore"),
        .testTarget(name: "Forge2DKitCoreTests", dependencies: ["Forge2DKitCore"])
    ]
)
