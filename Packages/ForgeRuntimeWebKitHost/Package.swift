// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeRuntimeWebKitHost",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeRuntimeWebKitHost", targets: ["ForgeRuntimeWebKitHost"]),
    ],
    dependencies: [
        .package(path: "../ForgeRuntimeKit"),
    ],
    targets: [
        .target(
            name: "ForgeRuntimeWebKitHost",
            dependencies: [
                .product(name: "ForgeRuntime", package: "ForgeRuntimeKit"),
            ]
        ),
        .testTarget(
            name: "ForgeRuntimeWebKitHostTests",
            dependencies: [
                "ForgeRuntimeWebKitHost",
                .product(name: "ForgeRuntime", package: "ForgeRuntimeKit"),
            ]
        ),
    ]
)
