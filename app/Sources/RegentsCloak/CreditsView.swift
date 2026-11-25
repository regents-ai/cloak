import AppKit
import SwiftUI

/// Native Credits & Open Source sheet listing every upstream integration,
/// local inference engine, model, and infrastructure component Cloak uses,
/// with clickable Website and GitHub/HuggingFace links plus offline access to
/// the bundled `THIRD_PARTY_NOTICES.md`.
struct CreditsView: View {
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showingNotices = false

    static func window() -> NSWindow {
        let window = ClosingWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Credits & Open Source"
        let content = NSHostingController(
            rootView: CreditsView(onClose: { [weak window] in window?.close() }))
        window.contentViewController = content
        window.contentMinSize = NSSize(width: 580, height: 480)
        window.setContentSize(NSSize(width: 620, height: 580))
        window.setFrameAutosaveName("sh.regents.cloak.window.credits")
        return window
    }

    private struct Entry: Identifiable {
        struct LinkItem: Identifiable {
            let title: String
            let url: URL
            var id: String { title + url.absoluteString }

            init(_ title: String, _ raw: String) {
                self.title = title
                self.url = URL(string: raw)!
            }
        }

        let name: String
        let summary: String
        let license: String?
        let links: [LinkItem]
        var id: String { name }
    }

    private static let integrations: [Entry] = [
        Entry(
            name: "Venice AI",
            summary: "Zero-data-retention inference and x402 Base USDC payments for Token Inference.",
            license: nil,
            links: [
                .init("Website", "https://venice.ai"),
                .init("Docs", "https://docs.venice.ai"),
                .init("GitHub", "https://github.com/veniceai"),
            ]
        ),
        Entry(
            name: "Boundless & Tempo (MPP)",
            summary: "Pay-per-request open-weight inference via HTTP 402 and Tempo USDC.e channels (mpp-rs).",
            license: "MIT / Apache-2.0",
            links: [
                .init("Boundless", "https://boundless.network"),
                .init("Tempo", "https://tempo.xyz"),
                .init("MPP", "https://mpp.dev"),
                .init("GitHub", "https://github.com/tempoxyz/mpp-rs"),
            ]
        ),
        Entry(
            name: "NEAR AI Cloud, Gateway & Dstack",
            summary: "Intel TDX and NVIDIA GPU hardware-attested enclaves and Trace Commons integration for NEAR AI Gateway mode.",
            license: nil,
            links: [
                .init("NEAR AI Cloud", "https://cloud.near.ai"),
                .init("NEAR AI Gateway", "https://gateway.near.ai"),
                .init("Trace Commons", "https://github.com/TraceCommons/trace-commons"),
                .init("Dstack", "https://github.com/Dstack-TEE/dstack"),
            ]
        ),
        Entry(
            name: "Open Anonymity (zkAPI)",
            summary: "Zero-knowledge unlinkable ETH payments powering zkAPI Anon Inference, inspired by Vitalik Buterin.",
            license: "MIT",
            links: [
                .init("Docs", "https://zkapi.openanonymity.ai"),
                .init("GitHub", "https://github.com/ethereum/zkapi"),
                .init("Reference Fork", "https://github.com/vbuterin/zkapi"),
            ]
        ),
        Entry(
            name: "Darkbloom (Eigen Labs)",
            summary: "Decentralized Apple Silicon inference serving runtime and network.",
            license: nil,
            links: [
                .init("Website", "https://darkbloom.dev"),
                .init("GitHub", "https://github.com/Layr-Labs/d-inference"),
            ]
        ),
    ]

    private static let engines: [Entry] = [
        Entry(
            name: "vmlx-swift & Apple MLX",
            summary: "Pure-Swift MLX, JANGH2, and DSpark speculative decoding runtime for Local Mode (Fast).",
            license: "MIT",
            links: [
                .init("Osaurus", "https://osaurus.ai"),
                .init("vmlx-swift", "https://github.com/osaurus-ai/vmlx-swift"),
                .init("mlx-swift", "https://github.com/ml-explore/mlx-swift"),
            ]
        ),
        Entry(
            name: "llama.cpp (ggml-org)",
            summary: "Local GGUF inference engine with Metal acceleration and GBNF grammar prompt rewriting.",
            license: "MIT",
            links: [
                .init("GitHub", "https://github.com/ggml-org/llama.cpp"),
            ]
        ),
    ]

    private static let models: [Entry] = [
        Entry(
            name: "Inkling 2 Mini",
            summary: "Local chat weights (OsaurusAI JANGH2, Unsloth & Xylolabs GGUFs, optional AtomicChat LoRA).",
            license: "Apache-2.0",
            links: [
                .init("Base", "https://huggingface.co/thinkingmachines/Inkling-2-Mini"),
                .init("JANGH2", "https://huggingface.co/OsaurusAI/Inkling-2-Mini-JANGH2"),
                .init("LoRA", "https://huggingface.co/AtomicChat/Inkling-2-Mini-Uncensored-GGUF"),
            ]
        ),
        Entry(
            name: "Qwen 3.5 9B",
            summary: "On-device prompt rewriter model used to strip writing style and personal metadata.",
            license: "Apache-2.0",
            links: [
                .init("Qwen", "https://huggingface.co/Qwen/Qwen3.5-9B"),
                .init("GGUF", "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF"),
            ]
        ),
    ]

    private static let infrastructure: [Entry] = [
        Entry(
            name: "The Tor Project",
            summary: "Bundled tor daemon providing isolated per-conversation circuits and cover traffic.",
            license: "BSD-3-Clause",
            links: [
                .init("Website", "https://www.torproject.org"),
                .init("Source", "https://gitlab.torproject.org/tpo/core/tor"),
            ]
        ),
        Entry(
            name: "Pi Coding Agent",
            summary: "Autonomous coding agent harness running inside Cloak's sealed Linux micro-VM.",
            license: "MIT",
            links: [
                .init("GitHub", "https://github.com/earendil-works/pi"),
            ]
        ),
        Entry(
            name: "Node.js",
            summary: "Linux arm64 runtime executing Pi inside the ephemeral micro-VM.",
            license: "MIT",
            links: [
                .init("Website", "https://nodejs.org"),
            ]
        ),
        Entry(
            name: "Sparkle",
            summary: "EdDSA-verified automatic software updates for macOS.",
            license: "MIT",
            links: [
                .init("Website", "https://sparkle-project.org"),
                .init("GitHub", "https://github.com/sparkle-project/Sparkle"),
            ]
        ),
        Entry(
            name: "Swift Argument Parser",
            summary: "Command-line interface parsing for the bundled cloak CLI.",
            license: "Apache-2.0",
            links: [
                .init("GitHub", "https://github.com/apple/swift-argument-parser"),
            ]
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                section("Cloud & Payment Integrations", entries: Self.integrations)
                section("Local Inference Engines", entries: Self.engines)
                section("Local Models", entries: Self.models)
                section("Privacy, Sandbox & Infrastructure", entries: Self.infrastructure)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)

            Divider()

            HStack(spacing: 12) {
                if Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") != nil {
                    Button("Full License Notices…") { showingNotices = true }
                }
                Link("regents.sh/cloak", destination: URL(string: "https://regents.sh/cloak")!)
                    .font(.callout)
                Link("@regents_sh", destination: URL(string: "https://x.com/regents_sh")!)
                    .font(.callout)
                Link("Feedback", destination: URL(string: "https://regents.sh/patchbay/cloak")!)
                    .font(.callout)
                Spacer()
                Button("Done") {
                    if let onClose { onClose() } else { dismiss() }
                }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 580, minHeight: 480)
        .textSelection(.enabled)
        .sheet(isPresented: $showingNotices) {
            LicenseNoticesSheet()
        }
    }

    private func section(_ title: String, entries: [Entry]) -> some View {
        Section(title) {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if let license = entry.license {
                            Text(license)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary.opacity(0.7), in: Capsule())
                        }
                        Spacer(minLength: 10)
                        HStack(spacing: 10) {
                            ForEach(entry.links) { item in
                                Link(item.title, destination: item.url)
                                    .font(.callout)
                                    .lineLimit(1)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Offline viewer for the bundled `THIRD_PARTY_NOTICES.md` license file.
private struct LicenseNoticesSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var noticesText: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "License notices file not found in this app bundle."
        }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Third-Party License Notices")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                Text(noticesText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(width: 600, height: 520)
    }
}
