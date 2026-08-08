// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForgeRepairCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeRepairCore", targets: ["ForgeRepairCore"]),
    ],
    targets: [
        .target(name: "ForgeRepairCore"),
        .testTarget(name: "ForgeRepairCoreTests", dependencies: ["ForgeRepairCore"]),
    ]
)
