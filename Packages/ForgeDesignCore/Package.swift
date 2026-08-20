// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ForgeDesignCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ForgeDesignCore", targets: ["ForgeDesignCore"])
    ],
    targets: [
        .target(name: "ForgeDesignCore"),
        .testTarget(name: "ForgeDesignCoreTests", dependencies: ["ForgeDesignCore"])
    ]
)
