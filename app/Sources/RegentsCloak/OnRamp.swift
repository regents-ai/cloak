import AppKit
import Foundation
import SwiftUI

/// Non-custodial Card / Apple Pay on-ramp (Decision N1a):
/// Funds Cloak's local wallets directly (`USDC` on Base for Pay-Per-Prompt /
/// Venice, `ETH` on Ethereum Mainnet for Paranoid (V)) without custodying keys
/// or exposing prompts.
///
/// Configuration (no secret keys are ever embedded in the Mac app binary):
/// - `CloakOnRampSessionURL` in Info.plist (default:
///   `https://regents.sh/api/cloak/onramp/session`): POSTs
///   `{"address","network","asset","amount_usd"}` to obtain a Stripe Crypto
///   Onramp or Coinbase Onramp `redirect_url` signed server-side.
/// - Alternatively, `CloakCoinbaseOnRampAppID` in Info.plist builds a direct
///   Coinbase Onramp checkout URL (`https://pay.coinbase.com/buy/select-asset`).
enum CardOnRamp {
    enum Target: Equatable, Identifiable {
        case baseUSDC(address: String)
        case ethereumETH(address: String)

        var id: String { "\(network):\(asset):\(address)" }

        var address: String {
            switch self {
            case .baseUSDC(let address), .ethereumETH(let address): address
            }
        }

        var network: String {
            switch self {
            case .baseUSDC: "base"
            case .ethereumETH: "ethereum"
            }
        }

        var asset: String {
            switch self {
            case .baseUSDC: "USDC"
            case .ethereumETH: "ETH"
            }
        }

        var title: String {
            switch self {
            case .baseUSDC: "Add USDC on Base"
            case .ethereumETH: "Add ETH on Ethereum"
            }
        }

        var subtitle: String {
            switch self {
            case .baseUSDC: "Delivered straight to your local Token Inference wallet."
            case .ethereumETH: "Delivered straight to your local zkAPI ETH wallet."
            }
        }

        var defaultAmount: Int {
            switch self {
            case .baseUSDC: 10
            case .ethereumETH: 10
            }
        }
    }

    enum Failure: LocalizedError {
        case invalidAmount
        case invalidEndpoint
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .invalidAmount:
                "Enter a whole dollar amount between $5 and $500."
            case .invalidEndpoint:
                "Card funding endpoint is not configured in this build."
            case .unavailable(let detail):
                detail
            }
        }
    }

    /// True only when this build has an explicit Coinbase Onramp App ID or a
    /// custom HTTPS session endpoint configured in `Info.plist`. Prevents
    /// shipping a prominent Card / Apple Pay button that hits an unconfigured
    /// endpoint.
    static var isConfigured: Bool {
        coinbaseAppID != nil || configuredSessionEndpoint != nil
    }

    private static var configuredSessionEndpoint: URL? {
        if let configured = Bundle.main.infoDictionary?["CloakOnRampSessionURL"] as? String,
            !configured.isEmpty, let url = URL(string: configured), url.scheme == "https"
        {
            return url
        }
        return nil
    }

    private static var sessionEndpoint: URL? {
        configuredSessionEndpoint ?? URL(string: "https://regents.sh/api/cloak/onramp/session")
    }

    private static var coinbaseAppID: String? {
        guard let id = Bundle.main.infoDictionary?["CloakCoinbaseOnRampAppID"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// Requests a checkout URL for `target` and `amountUSD`. Sends ONLY the
    /// destination address, network, asset, and dollar amount — never chat data,
    /// prompts, or private keys.
    static func checkoutURL(for target: Target, amountUSD: Int) async throws(Failure) -> URL {
        guard (5...500).contains(amountUSD) else { throw .invalidAmount }

        // Direct Coinbase Onramp URL if a public App ID is configured in Info.plist.
        if let appID = coinbaseAppID {
            var components = URLComponents(string: "https://pay.coinbase.com/buy/select-asset")!
            let addresses = #"{"\#(target.address)":["\#(target.network)"]}"#
            let assets = #"["\#(target.asset)"]"#
            components.queryItems = [
                URLQueryItem(name: "appId", value: appID),
                URLQueryItem(name: "addresses", value: addresses),
                URLQueryItem(name: "assets", value: assets),
                URLQueryItem(name: "presetFiatAmount", value: String(amountUSD)),
                URLQueryItem(name: "fiatCurrency", value: "USD"),
            ]
            if let url = components.url { return url }
        }

        // Server-signed Stripe Crypto Onramp / Coinbase session endpoint.
        guard let endpoint = sessionEndpoint else { throw .invalidEndpoint }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let payload: [String: Any] = [
            "address": target.address,
            "network": target.network,
            "asset": target.asset,
            "amount_usd": amountUSD,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw .unavailable("Couldn't reach the card checkout service. Check your connection or send \(target.asset) directly to the wallet address.")
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw .unavailable("Card checkout isn't active on this endpoint yet. You can still send \(target.asset) directly to your local wallet address.")
        }
        struct SessionReply: Decodable {
            let url: URL?
            let redirect_url: URL?
            let hosted_url: URL?
        }
        guard let decoded = try? JSONDecoder().decode(SessionReply.self, from: data),
            let checkout = decoded.url ?? decoded.redirect_url ?? decoded.hosted_url,
            checkout.scheme == "https"
        else {
            throw .unavailable("Card checkout returned an unexpected response. You can still fund directly via your wallet address.")
        }
        return checkout
    }
}

/// Clean macOS sheet for non-custodial Card / Apple Pay funding (Decision N1a).
struct CardOnRampSheet: View {
    let target: CardOnRamp.Target
    let onRefresh: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String
    @State private var loading = false
    @State private var openedBrowser = false
    @State private var errorMessage: String?

    init(target: CardOnRamp.Target, onRefresh: @escaping () -> Void) {
        self.target = target
        self.onRefresh = onRefresh
        _amountText = State(initialValue: String(target.defaultAmount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "creditcard.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title)
                        .font(.headline)
                    Text(target.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Amount (USD)")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach([5, 10, 25, 50], id: \.self) { preset in
                        Button("$\(preset)") {
                            amountText = String(preset)
                            errorMessage = nil
                        }
                        .buttonStyle(.bordered)
                        .tint(amountText == String(preset) ? .accentColor : nil)
                    }
                    HStack(spacing: 4) {
                        Text("$")
                            .foregroundStyle(.secondary)
                        TextField("Amount", text: $amountText)
                            .labelsHidden()
                            .frame(width: 64)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Destination (your local Cloak wallet)")
                    .font(.subheadline.weight(.semibold))
                Text(target.address)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Label {
                Text("Card & Apple Pay checkout connects directly to the payment provider (not through Tor) to send \(target.asset) straight to this Mac's wallet. Cloak never sees your card details, and your AI prompts stay completely separate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if openedBrowser {
                Label("Checkout opened in your browser. Once it finishes, click Check Balance.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }

            HStack {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if openedBrowser {
                    Button("Check Balance") {
                        onRefresh()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        startCheckout()
                    } label: {
                        if loading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Continue with Card / Apple Pay", systemImage: "arrow.up.right")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func startCheckout() {
        guard let amount = Int(amountText.trimmingCharacters(in: .whitespaces)), (5...500).contains(amount) else {
            errorMessage = CardOnRamp.Failure.invalidAmount.errorDescription
            return
        }
        loading = true
        errorMessage = nil
        Task {
            do {
                let url = try await CardOnRamp.checkoutURL(for: target, amountUSD: amount)
                NSWorkspace.shared.open(url)
                openedBrowser = true
            } catch {
                errorMessage = error.localizedDescription
            }
            loading = false
        }
    }
}
