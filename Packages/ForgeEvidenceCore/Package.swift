// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeEvidenceCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeEvidenceCore", targets: ["ForgeEvidenceCore"]),
    ],
    targets: [
        .target(name: "ForgeEvidenceCore"),
        .testTarget(
            name: "ForgeEvidenceCoreTests",
            dependencies: ["ForgeEvidenceCore"]
        ),
    ]
)
