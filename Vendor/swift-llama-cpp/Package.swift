// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let llamaVersion = "b6102"
let llamaChecksum = "257b8ffbdda68b377e1b75cd23055b201b0e9a24e18d5a42f2960456776eab8a"
let mlxSwiftLMRevision = "5c1d95aae725db4cc34eaa60d5b820191940b685"

let package = Package(
    name: "swift-llama-cpp",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "SwiftLlama",
            targets: ["SwiftLlama"]),
    ],
    dependencies: [
        // Pin the exact Aug 10, 2026 mlx-swift-lm head that includes Nanbeige4.2
        // support plus the new single-dispatch TurboFlash short-context path.
        // NovaForge's app target still supports iOS 26, so keep the optional
        // iOS-27-only FoundationModelsIntegration trait disabled here.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: mlxSwiftLMRevision,
            traits: []
        ),
        // mlx-swift-lm declares compatibility from 0.31.4. Pin 0.31.4 here so
        // NovaForge's current Swift 6.2/Xcode 26-era toolchain does not resolve
        // mlx-swift 0.31.6, whose manifest requires Swift tools 6.3.
        .package(
            url: "https://github.com/ml-explore/mlx-swift.git",
            exact: "0.31.4"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            from: "0.9.0"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            from: "1.3.0"
        ),
    ],
    targets: [
        .target(
            name: "SwiftLlama",
            dependencies: [
                "llama",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/\(llamaVersion)/llama-\(llamaVersion)-xcframework.zip",
            checksum: llamaChecksum
        ),
        .testTarget(
            name: "SwiftLlamaTests",
            dependencies: ["SwiftLlama"],
            resources: [.copy("Resources")]
        ),
    ]
)
