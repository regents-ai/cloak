import SwiftUI

/// First-time Terms of Service & Privacy Policy acknowledgment gate shown
/// before any wallet or funding screen (`WalletView` and Settings → Wallets).
/// Acceptance is stored strictly locally on this Mac (`AppSettings.walletTermsVersion`)
/// and never transmitted anywhere.
struct WalletTermsGateView: View {
    let settings: AppSettings
    var readOnly: Bool = false
    var onCancel: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var acceptedTerms = false
    @State private var acceptedPrivacy = false

    private static let walletGuideURL = URL(string: "https://regents.sh/docs/cloak/wallets")!

    private var canSign: Bool {
        acceptedTerms && acceptedPrivacy
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Terms of Service & Privacy Policy")
                            .font(.headline)
                        BetaBadge()
                    }
                    Text(
                        readOnly
                            ? (settings.walletTermsAcceptedAt.map {
                                "Signed locally on this Mac on \($0.formatted(date: .abbreviated, time: .shortened))."
                            } ?? "Signed locally on this Mac.")
                            : "Review and sign before viewing Cloak's wallets and funding screens."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: Self.walletGuideURL) {
                    HStack(spacing: 3) {
                        Text("Wallet guide")
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            Divider()

            // Scrollable Terms & Privacy body
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TermsSection(
                        symbol: "exclamationmark.shield",
                        tint: .orange,
                        title: "Terms of Service (Beta & Wallet Risk)",
                        bullets: [
                            "**Beta software (\"as is\"):** Regents Cloak is open-source beta software offered by Regents Labs without warranties or guarantees of any kind.",
                            "**Funds are not guaranteed:** Regents Labs never custodies your keys, cannot recover lost keys or deposits, and does not guarantee the safety or availability of any funds you transfer.",
                            "**Blockchains are not always safe:** Public blockchains, smart contracts, payment channels, RPC nodes, and bridges carry inherent technical and financial risks, including bugs, exploits, failed transactions, or permanent loss of funds.",
                            "**Unaudited contracts & bridging:** Neither Cloak's wallet integrations nor the underlying third-party smart contracts and bridges (Tempo / MPP, Base / x402 / USDC, Ethereum L1 / zkAPI) have been audited by Regents Labs.",
                            "**Self-custody & limits:** Keys stay strictly on this Mac and never sync to iCloud. Keep balances small ($5–$20), withdraw or back up before wiping or switching Macs, and note the 30-day protocol limit on untouched zkAPI deposits.",
                        ]
                    )

                    TermsSection(
                        symbol: "hand.raised",
                        tint: .accentColor,
                        title: "Privacy Policy",
                        bullets: [
                            "**Zero data sent to Regents Labs (local storage only):** Regents Labs has no servers in your chat or payment path and never collects, logs, stores, or sells your prompts, chats, wallet addresses, private keys, IP address, or telemetry. Cloak stores your saved chats (encrypted), settings, local spend receipts, and self-custodial wallet keys (in macOS Keychain, never synced to iCloud) **exclusively on this Mac**.",
                            "**Third-party integrations:** External services Cloak connects to (Boundless, Venice AI, NEAR AI Cloud, zkAPI, Tempo, Base, Ethereum RPCs, Hugging Face model hosts, and Darkbloom) are chosen to avoid storing or sharing data where possible, **but they are independent third parties** outside Regents Labs' control and governed by their own terms and privacy policies.",
                            "**Tor vs. direct connections:** When Tor is enabled, your IP is masked through Tor relays. When you turn Tor off (direct NEAR or direct Token Inference), the selected provider and RPC see your Mac's IP address.",
                            "**Opt-in NEAR AI Traces:** Trace export is off by default. If you enable **Share traces** and upload exported chats to NEAR AI Gateway / Trace Commons, those chats are shared with that entity under its terms.",
                        ]
                    )
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
            .textSelection(.enabled)

            Divider()

            if readOnly {
                HStack {
                    Label("Stored locally on this Mac only — never transmitted.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") {
                        if let onCancel { onCancel() } else { dismiss() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $acceptedTerms) {
                        Text("I accept the Beta Terms of Service and understand that funds are not guaranteed and smart contracts/bridges have not been audited by Regents Labs.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $acceptedPrivacy) {
                        Text("I have read the Privacy Policy, including third-party integration boundaries and opt-in NEAR AI Traces sharing.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)

                    HStack(spacing: 10) {
                        Label("Signed locally on this Mac only — never sent anywhere.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let onCancel {
                            Button("Cancel", action: onCancel)
                                .keyboardShortcut(.cancelAction)
                        }
                        Button("Sign & Continue") {
                            settings.acceptWalletTerms()
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!canSign)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
        }
    }
}

private struct TermsSection: View {
    let symbol: String
    let tint: Color
    let title: String
    let bullets: [LocalizedStringKey]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(bullet)
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
