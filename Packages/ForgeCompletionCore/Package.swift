// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForgeCompletionCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeCompletionCore", targets: ["ForgeCompletionCore"]),
    ],
    targets: [
        .target(name: "ForgeCompletionCore"),
        .testTarget(name: "ForgeCompletionCoreTests", dependencies: ["ForgeCompletionCore"]),
    ]
)
