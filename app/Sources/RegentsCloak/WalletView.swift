import AppKit
import CloakChat
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Development mode's wallet: made here on Create, its address to add funds
/// to, its balance, the deposit chats are paid from, and the model they go
/// to. A button that reaches the network is off only where its request is
/// certain to stop: Cloak not running, so nothing reaches the guest; no
/// deposit, as the network last showed the wallet; or, for Withdraw, the
/// network's waiting time still running. Never for a press under way.
struct WalletView: View {
    @Bindable var wallet: Wallet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let running = wallet.supervisor.phase == .running
        VStack(spacing: 0) {
            DevelopmentBar()
            Form {
                if !running {
                    Section {
                        Text("Start Cloak to use the wallet.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let stop = wallet.stop ?? wallet.readStop {
                    Section {
                        StopRow(stop: stop) { wallet.dismiss() }
                    }
                }
                switch wallet.presence {
                case .looking:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                case .unreadable:
                    Section {
                        Text("Cloak couldn't read the wallet.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Try Again") { Task { await wallet.find() } }
                        }
                    }
                case .held(let address):
                    Account(wallet: wallet, address: address)
                    Holding(wallet: wallet, running: running)
                    Models(wallet: wallet)
                case .absent, .creating:
                    Section {
                        Text("Cloak makes one wallet on this Mac. You add funds to it, and it pays for each chat you send.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Create") { Task { await wallet.create() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(wallet.presence == .creating || !running)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack(spacing: 10) {
                if wallet.working > 0 || wallet.presence == .creating {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Refresh") { Task { await wallet.refresh() } }
                    .disabled(wallet.presence.address == nil || !running)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            // Level with the form's boxes.
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        // As tall as what it shows, up to 640 points; past that, or past
        // the room the Chat window leaves a sheet, the form scrolls.
        .frame(width: 540)
        .frame(maxHeight: 640)
        .task { await wallet.refresh() }
    }
}

/// Where to add funds, and what is there.
private struct Account: View {
    let wallet: Wallet
    let address: String

    var body: some View {
        Section("Wallet") {
            LabeledContent("Address") {
                HStack(spacing: 4) {
                    Text(address)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    } label: {
                        // A larger target than the icon alone.
                        Label("Copy", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                            .frame(width: 24, height: 24)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .hover(Circle())
                    .help("Copy")
                    CodeButton(address: address)
                }
            }
            LabeledContent("Token", value: "USDC.e on Tempo")
            if let look = wallet.look {
                if !look.setup {
                    Label("The provider no longer names USDC.e on Tempo. Don't add funds.", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                LabeledContent("Balance", value: look.balance.text)
                if wallet.lacksFunds {
                    Text("Add at least \(look.least.text) to send.")
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Balance", value: "—")
            }
        }
    }
}

/// The address as a QR code, for a phone's wallet to scan, in a popover
/// from the button beside Copy, with the address in full under it to check
/// against. Shown only.
private struct CodeButton: View {
    let address: String
    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Label("Show QR Code", systemImage: "qrcode")
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .hover(Circle())
        .help("Show QR Code")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            if let code = QRCode.image(for: address) {
                let side = CGFloat(code.width) * QRCode.point
                VStack(spacing: 10) {
                    // A whole number of pixels per module at any display
                    // scale, and no smoothing, so each module's edge is sharp.
                    Image(code, scale: 1, label: Text("QR code of the address"))
                        .interpolation(.none)
                        .resizable()
                        .frame(width: side, height: side)
                        .clipShape(.rect(cornerRadius: 6))
                    // On one line, so it is never broken with a hyphen.
                    Text(address)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize()
                }
                .padding(16)
            }
        }
    }
}

/// A QR code of exactly a text, one pixel per module, black on white inside
/// a white quiet zone at least four modules wide, white in light and dark
/// alike, since that is what a camera reads.
enum QRCode {
    /// The points each module takes on screen.
    static let point: CGFloat = 5

    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, let code = CIContext().createCGImage(output, from: output.extent) else { return nil }
        // CoreImage leaves a margin of one module; four more make the quiet
        // zone.
        let quiet = 4
        let side = code.width + 2 * quiet
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: quiet, y: quiet, width: code.width, height: code.height))
        return context.makeImage()
    }
}

/// The deposit chats are paid from, at the size the provider suggests: what
/// it holds, and the two ways to end it.
private struct Holding: View {
    let wallet: Wallet
    let running: Bool

    var body: some View {
        let look = wallet.look
        // A deposit the network shows closed is already forgotten.
        let deposit = look?.deposit.flatMap { $0.gone == true ? nil : $0 }
        let none = look != nil && deposit == nil
        Section("Deposit") {
            LabeledContent("Held") {
                if let deposit {
                    Text("\(deposit.deposit.text), \(deposit.spent.text) spent")
                } else {
                    Text(none ? "None" : "—")
                }
            }
            HStack {
                Text(none ? "Nothing to refund." : "Refunds what's unspent.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { Task { await wallet.close() } }
                    .disabled(!running || none)
            }
            TimelineView(.everyMinute) { context in
                let wait = deposit?.withdrawAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                let waiting = wait.map { context.date < $0 } ?? false
                HStack {
                    Text(withdrawWords(none: none, wait: wait, waiting: waiting))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Withdraw") { Task { await wallet.withdraw() } }
                        .disabled(!running || none || waiting)
                }
            }
        }
    }

    private func withdrawWords(none: Bool, wait: Date?, waiting: Bool) -> String {
        guard !none else { return "Nothing to take back." }
        guard let wait else { return "Without the provider: asks the network to close it, then takes it back 15 minutes later." }
        return waiting ? "Ready at \(wait.formatted(date: .omitted, time: .shortened))." : "Takes it back now."
    }
}

/// The model chats go to, with its price.
private struct Models: View {
    @Bindable var wallet: Wallet

    var body: some View {
        let models = (wallet.look?.models ?? []).sorted { $0.pricing.output < $1.pricing.output }
        Section {
            Picker("Model", selection: $wallet.model) {
                if !models.contains(where: { $0.id == wallet.model }) {
                    Text(wallet.model).tag(wallet.model)
                }
                ForEach(models) { model in
                    Text("\(model.id)  \(model.pricing.input.price) in, \(model.pricing.output.price) out").tag(model.id)
                }
            }
        } footer: {
            Text("Prices are per million tokens.")
                .foregroundStyle(.secondary)
        }
    }
}

/// The Development mark, with what it means for the person.
struct DevelopmentBar: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Development")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.2), in: Capsule())
            Text("The provider can link your chats, because one wallet pays for all of them.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.06))
        .accessibilityElement(children: .combine)
    }
}

/// Why a request stopped, in plain words.
struct StopRow: View {
    let stop: RemoteStop
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.title)
                    .fontWeight(.medium)
                Text(stop.words)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hover(Circle(), outset: 4)
                .help("Dismiss")
        }
    }
}

extension RemoteStop {
    var title: String {
        switch code {
        case .noFunds: "No funds"
        case .walletRefused: "Wallet refused"
        case .modelUnavailable: "Model unavailable"
        case .torDown: "Tor down"
        case .answerRefused: "No answer"
        case .failed: "Failed"
        case .unreachable: "Not running"
        }
    }

    var words: String {
        switch code {
        case .noFunds: "Add USDC.e on Tempo to the wallet, then try again."
        case .walletRefused: "The provider turned this wallet away."
        case .modelUnavailable: "This model can't be used now. Pick another in Wallet."
        case .torDown: "Cloak couldn't reach the network through Tor. Try again."
        case .answerRefused: "The model declined to answer."
        case .failed: "Something went wrong. Try again."
        case .unreachable: "Start Cloak, then try again."
        }
    }
}

extension Amount {
    /// "1.00 USDC.e"
    var text: String {
        "\(dollars.formatted(.number.precision(.fractionLength(2...6)))) USDC.e"
    }
}

extension Double {
    /// "$0.27"
    fileprivate var price: String {
        formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
    }
}
