// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalOnlyNetworkAuditCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LocalOnlyNetworkAuditCore", targets: ["LocalOnlyNetworkAuditCore"]),
    ],
    targets: [
        .target(name: "LocalOnlyNetworkAuditCore"),
        .testTarget(name: "LocalOnlyNetworkAuditCoreTests", dependencies: ["LocalOnlyNetworkAuditCore"]),
    ]
)
