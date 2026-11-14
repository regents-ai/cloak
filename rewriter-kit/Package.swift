// swift-tools-version: 6.2

import PackageDescription

// The rewrite worker's protocol and pins (llama-worker/ is its one user): the
// frames to and from the host supervisor, the daemon's request, the reply
// shapes and the model pins.
let package = Package(
    name: "rewriter-kit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "RewriterKit", targets: ["RewriterKit"])],
    targets: [
        .target(
            name: "RewriterKit",
            // The model pins are built into the worker, so the signed binary
            // decides which files it will load.
            resources: [.embedInCode("models.json")])
    ]
)
