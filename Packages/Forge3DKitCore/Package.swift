// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Forge3DKitCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Forge3DKitCore", targets: ["Forge3DKitCore"])
    ],
    targets: [
        .target(name: "Forge3DKitCore"),
        .testTarget(name: "Forge3DKitCoreTests", dependencies: ["Forge3DKitCore"])
    ]
)
