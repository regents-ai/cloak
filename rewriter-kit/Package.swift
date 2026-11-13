// swift-tools-version: 6.2

import PackageDescription

// What both rewriter workers share while decision 8 compares two engines
// (docs/plan.md): the frames to and from the host supervisor, the daemon's
// request, the reply shapes and the model pins. The engine that loses is
// deleted, and this package with it folds back into the one that stays.
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
