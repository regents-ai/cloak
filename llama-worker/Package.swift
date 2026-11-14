// swift-tools-version: 6.2

import Foundation
import PackageDescription

let here = URL(filePath: #filePath).deletingLastPathComponent()
// The worker runs in the App Sandbox, which needs a bundle identifier; a
// command-line tool carries it in an Info.plist section of its own binary.
let infoPlist = here.appending(path: "Info.plist").path
// llama.cpp's headers, from the source pinned in reference/sources.json, and
// the static archive build-llama.sh builds from it.
let llama = here.appending(path: "../reference/src/llama.cpp").standardizedFileURL.path
let archive = here.appending(path: ".llama/lib").path

let package = Package(
    name: "cloak-rewriter-llama",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../rewriter-kit")],
    targets: [
        // The C interface to llama.cpp (cloak_llama.h).
        .target(
            name: "CLlama",
            cxxSettings: [
                .unsafeFlags([
                    "-I", "\(llama)/include", "-I", "\(llama)/ggml/include", "-I", "\(llama)/common",
                    "-I", "\(llama)/vendor",
                ])
            ],
            linkerSettings: [
                .unsafeFlags(["-L", archive]),
                .linkedLibrary("llamacpp"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
            ]),
        // The reply grammar (reference/rewrite-reply.gbnf) is built in, as the
        // model pins are, so the signed binary decides what it decodes under.
        .target(
            name: "LlamaEngine",
            dependencies: ["CLlama", .product(name: "RewriterKit", package: "rewriter-kit")],
            resources: [.embedInCode("rewrite-reply.gbnf")]),
        .executableTarget(
            name: "cloak-rewriter-llama",
            dependencies: ["LlamaEngine", "CLlama", .product(name: "RewriterKit", package: "rewriter-kit")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
            ]),
    ],
    cxxLanguageStandard: .cxx17
)
