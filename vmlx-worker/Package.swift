// swift-tools-version: 6.1

import Foundation
import PackageDescription

let here = URL(filePath: #filePath).deletingLastPathComponent()
// App Sandbox requires a bundle identifier embedded in the helper binary.
let infoPlist = here.appending(path: "Info.plist").path

let package = Package(
    name: "cloak-worker-vmlx",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../rewriter-kit"),
        // Pure-Swift MIT-licensed MLX + JANGH2 + DSpark MTP runtime (zero Python).
        .package(
            url: "https://github.com/osaurus-ai/vmlx-swift",
            revision: "52fdb628936dda1e87a315252e62524ee301b778"
        ),
    ],
    targets: [
        .executableTarget(
            name: "cloak-worker-vmlx",
            dependencies: [
                .product(name: "RewriterKit", package: "rewriter-kit"),
                .product(name: "MLX", package: "vmlx-swift"),
                .product(name: "MLXLLM", package: "vmlx-swift"),
                .product(name: "MLXLMCommon", package: "vmlx-swift"),
                .product(name: "MLXHuggingFace", package: "vmlx-swift"),
                .product(name: "VMLXTokenizers", package: "vmlx-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist,
                ])
            ]
        ),
    ]
)
