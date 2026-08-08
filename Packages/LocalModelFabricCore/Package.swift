// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalModelFabricCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LocalModelFabricCore", targets: ["LocalModelFabricCore"]),
    ],
    dependencies: [
        .package(path: "../AgentHarnessKit"),
    ],
    targets: [
        .target(
            name: "LocalModelFabricCore",
            dependencies: [
                .product(name: "AgentDomain", package: "AgentHarnessKit"),
            ]
        ),
        .testTarget(
            name: "LocalModelFabricCoreTests",
            dependencies: [
                "LocalModelFabricCore",
                .product(name: "AgentDomain", package: "AgentHarnessKit"),
            ]
        ),
    ]
)
