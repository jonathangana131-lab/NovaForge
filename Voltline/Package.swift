// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Voltline",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "VoltlineSim", targets: ["VoltlineSim"])
    ],
    targets: [
        .target(name: "VoltlineSim"),
        .testTarget(name: "VoltlineSimTests", dependencies: ["VoltlineSim"])
    ]
)
