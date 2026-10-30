// swift-tools-version: 6.2

import Foundation
import PackageDescription

// The worker runs in the App Sandbox, which needs a bundle identifier; a
// command-line tool carries it in an Info.plist section of its own binary.
let infoPlist = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Info.plist").path

// Every dependency is pinned to one exact version or commit (spec MAC02,
// S17); Package.resolved records the rest of the graph.
let package = Package(
    name: "cloak-rewriter",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            revision: "f5b0677f6b52b81d068871611cfcb82d1e7a0005",
            traits: []),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
    ],
    targets: [
        .executableTarget(
            name: "cloak-rewriter",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            // The model pins are built into the worker, so the signed binary
            // decides which files it will load.
            resources: [.embedInCode("models.json")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
            ])
    ]
)
