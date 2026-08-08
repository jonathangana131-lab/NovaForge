// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForgePlanMissionAdapter",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ForgePlanMissionAdapter", targets: ["ForgePlanMissionAdapter"])
    ],
    dependencies: [
        .package(path: "../ForgePlanCore"),
        .package(path: "../AgentHarnessKit")
    ],
    targets: [
        .target(
            name: "ForgePlanMissionAdapter",
            dependencies: [
                .product(name: "ForgePlanCore", package: "ForgePlanCore"),
                .product(name: "AgentDomain", package: "AgentHarnessKit")
            ]
        ),
        .testTarget(
            name: "ForgePlanMissionAdapterTests",
            dependencies: [
                "ForgePlanMissionAdapter",
                .product(name: "ForgePlanCore", package: "ForgePlanCore"),
                .product(name: "AgentDomain", package: "AgentHarnessKit")
            ]
        )
    ]
)
