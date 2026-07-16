// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentHarnessKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AgentDomain", targets: ["AgentDomain"]),
        .library(name: "AgentEngine", targets: ["AgentEngine"]),
        .library(name: "AgentTools", targets: ["AgentTools"]),
        .library(name: "AgentProviders", targets: ["AgentProviders"]),
        .library(name: "AgentStore", targets: ["AgentStore"]),
        .library(name: "AgentShadow", targets: ["AgentShadow"]),
        .library(name: "AgentPolicy", targets: ["AgentPolicy"]),
        .library(name: "AgentTransport", targets: ["AgentTransport"]),
    ],
    targets: [
        .target(name: "AgentDomain"),
        .target(
            name: "AgentReducerCore",
            dependencies: ["AgentDomain"]
        ),
        .target(
            name: "AgentEngine",
            dependencies: [
                "AgentDomain",
                "AgentPolicy",
                "AgentProviders",
                "AgentReducerCore",
                "AgentStore",
                "AgentTools",
            ]
        ),
        .target(
            name: "AgentTools",
            dependencies: ["AgentDomain"]
        ),
        .target(
            name: "AgentProviders",
            dependencies: ["AgentDomain", "AgentTools"]
        ),
        .target(
            name: "AgentStore",
            dependencies: ["AgentDomain", "AgentReducerCore"]
        ),
        .target(
            name: "AgentShadow",
            dependencies: [
                "AgentDomain",
                "AgentProviders",
                "AgentStore",
                "AgentTools",
            ]
        ),
        .target(
            name: "AgentPolicy",
            dependencies: ["AgentDomain", "AgentTools"]
        ),
        .target(
            name: "AgentTransport",
            dependencies: ["AgentDomain"]
        ),
        .testTarget(
            name: "AgentDomainTests",
            dependencies: ["AgentDomain"]
        ),
        .testTarget(
            name: "AgentEngineTests",
            dependencies: [
                "AgentDomain",
                "AgentEngine",
                "AgentPolicy",
                "AgentProviders",
                "AgentStore",
                "AgentTools",
            ]
        ),
        .testTarget(
            name: "AgentToolContractTests",
            dependencies: ["AgentDomain", "AgentTools"]
        ),
        .testTarget(
            name: "AgentProviderContractTests",
            dependencies: ["AgentDomain", "AgentProviders", "AgentTools"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "AgentStoreTests",
            dependencies: ["AgentDomain", "AgentStore"]
        ),
        .testTarget(
            name: "AgentShadowTests",
            dependencies: [
                "AgentDomain",
                "AgentProviders",
                "AgentShadow",
                "AgentStore",
                "AgentTools",
            ]
        ),
        .testTarget(
            name: "AgentPolicyTests",
            dependencies: ["AgentDomain", "AgentPolicy", "AgentTools"]
        ),
        .testTarget(
            name: "AgentTransportTests",
            dependencies: ["AgentDomain", "AgentTransport"]
        ),
    ]
)
