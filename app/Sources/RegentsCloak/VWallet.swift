import AppKit
import CloakChat
import SwiftUI

/// V's wallet, in the Wallet sheet of a V chat (docs/zkapi-mac-side.md,
/// section 3): the payer's Ethereum address to send ETH to, the deposit
/// each request is paid from with a new key, and the model V chats go to.
/// Every figure is the payer's, in ETH; the one figure in dollars is the
/// amount its owner asked to deposit. Deposit, Withdraw and Transfer each
/// ask the payer for a quote and show it where the press was made, in
/// place of the button pressed; the review's button is the one place an
/// approve is sent from. A money button is off only where the chain at the
/// latest block read shows its request certain to fail, with why beside it;
/// never for a press under way, and every press is sent. While Cloak is not
/// running, nothing is read and none of this shows: the sheet's `StartRow`
/// is the way on.
struct VWallet: View {
    let payer: Payer
    @Bindable var settings: AppSettings
    let running: Bool
    /// Preserved across Review Cancel so the user never has to retype addresses
    /// or amounts after inspecting a quote.
    @State private var depositText = "10"
    @State private var transferDestination = ""
    @State private var transferAmount = ""

    var body: some View {
        // Show untargeted press errors or read errors at the top; deposit,
        // withdrawal, and transfer errors render inline inside their own section.
        if let stop = payer.stop,
            payer.stopTarget == nil || payer.state == .unread
                || { if case .failed = payer.state { return payer.stopTarget != .transfer }; return false }()
        {
            Section {
                PressStopRow(payer: payer, stop: stop)
            }
            .id("v-stop-banner")
        } else if let stop = payer.readStop {
            Section {
                ReadStopRow(payer: payer, stop: stop)
            }
        }
        switch payer.state {
        case .unread:
            // Until a read stops; then its row says why, with Try Again.
            if running, payer.readStop == nil {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reading zkAPI ETH wallet over Tor…")
                                .font(.callout.weight(.medium))
                            Text("Loading Ethereum address, balance, and deposit.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        case .failed(let fault):
            Section {
                Failed(payer: payer, fault: fault)
            }
            // The ETH on the address can still be seen and sent out.
            if let funding = payer.funding {
                AddressSection(
                    payer: payer, funding: funding, destination: $transferDestination, amount: $transferAmount)
            }
        default:
            if let funding = payer.funding {
                AddressSection(
                    payer: payer, funding: funding, destination: $transferDestination, amount: $transferAmount)
            }
            DepositSection(payer: payer, settings: settings, depositText: $depositText)
            ModelSection(payer: payer, settings: settings)
        }
    }
}

/// The payer's own address on Ethereum, to send ETH to, as Copy and a QR
/// code, with what alone may be sent to it; the ETH there now; and
/// Transfer…, which sends an amount of it to an address, both typed in, or
/// its quote under review.
private struct AddressSection: View {
    let payer: Payer
    let funding: FundingStatus
    @Binding var destination: String
    @Binding var amount: String
    @State private var onRampTarget: CardOnRamp.Target?
    /// The payer reads and sends ETH on Ethereum Mainnet and nothing else,
    /// and its key never leaves the guest.
    private static let only = "Send ETH on Ethereum Mainnet only — other assets can't be recovered."

    var body: some View {
        Section {
            LabeledContent("Address") {
                HStack(spacing: 4) {
                    Text(funding.address)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    CopyButton(text: funding.address)
                    CodeButton(address: funding.address, only: Self.only)
                }
            }
            LabeledContent("Asset", value: "ETH · Ethereum Mainnet")
            Only(words: Self.only)
            LabeledContent("Wallet Balance", value: Ether.text(wei: funding.ethBalance) ?? "—")
            Text("Step 1: Send ETH here on Ethereum Mainnet. Step 2: Move ETH into your zkAPI Deposit below to unlock unlinkable one-time keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let returning = payer.returning, returning.phase == "return_pending" {
                LabeledContent("Pending") {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        if let hash = returning.transactionHash {
                            Hash(hash)
                        }
                    }
                }
            } else if let returning = payer.returning, returning.phase == "reverted" {
                Label("The last ETH transfer reverted on-chain. Your balance minus gas stays in this wallet.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let stop = payer.stop, payer.stopTarget == .transfer {
                PressStopRow(payer: payer, stop: stop)
                    .id("v-stop-banner")
            }
            if let review = payer.review, case .transfer = review {
                ReviewRows(payer: payer, review: review)
            } else {
                HStack(spacing: 8) {
                    if CardOnRamp.isConfigured {
                        Button {
                            onRampTarget = .ethereumETH(address: funding.address)
                        } label: {
                            Label("Add ETH with Card / Apple Pay", systemImage: "creditcard")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if payer.activity == .quotingTransfer {
                        ProgressView()
                            .controlSize(.small)
                        Text("Fetching transfer quote over Tor…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let block = payer.transferBlock, payer.activity != .quotingTransfer {
                        Text(block.words)
                            .foregroundStyle(.secondary)
                    }
                    TransferButton(payer: payer, balance: funding.ethBalance, destination: $destination, amount: $amount)
                        .disabled(payer.transferBlock != nil || payer.activity != nil)
                }
            }
        } header: {
            Text("ETH Mainnet Wallet")
        } footer: {
            Text("Beta: keep working balances small. This Ethereum Mainnet wallet stays encrypted on this Mac only (not synced to iCloud) and has no separate seed export — withdraw ETH before wiping or switching Macs, or funds will be permanently lost. [Wallet security & recovery](https://regents.sh/docs/cloak/wallets).")
                .foregroundStyle(.secondary)
        }
        .sheet(item: $onRampTarget) { target in
            CardOnRampSheet(target: target) {
                payer.follow()
            }
        }
    }
}

/// Transfer…: an address and an amount in ETH typed in a popover, checked
/// when Review is pressed, and the payer's quote for sending that much
/// there. Max types the whole balance, and the whole balance, typed or
/// from Max, asks for all of it less the fee, which the review shows: no
/// transfer can send all of an address's ETH and pay a fee on top.
private struct TransferButton: View {
    let payer: Payer
    /// The address's ETH, in wei as a decimal string.
    let balance: String
    @Binding var destination: String
    @Binding var amount: String
    @State private var open = false
    @State private var wrong: Wrong?

    private enum Wrong: String {
        case address = "Enter an Ethereum address: 0x and 40 characters."
        case amount = "Enter an amount in ETH, such as 0.005."
        case tooMuch = "That's more than the balance."
    }

    var body: some View {
        Button("Transfer…") { open = true }
            .tip("Sends ETH from this wallet to an address you type.")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Text("To")
                            TextField("To", text: $destination, prompt: Text("0x…"))
                                .font(.body.monospaced())
                                .frame(width: 360)
                                .accessibilityLabel("Recipient Ethereum address")
                        }
                        GridRow {
                            Text("Amount")
                            HStack(spacing: 8) {
                                TextField("Amount", text: $amount, prompt: Text("0.0"))
                                    .monospacedDigit()
                                    .frame(width: 160)
                                    .accessibilityLabel("Amount in ETH")
                                Text("ETH")
                                    .foregroundStyle(.secondary)
                                Button("Max") { amount = Ether.exact(wei: balance) ?? "" }
                                    .tip("All of the balance, less the fee.")
                            }
                        }
                    }
                    .labelsHidden()
                    .onSubmit(review)
                    if let wrong {
                        Text(wrong.rawValue)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    Text("Beta: Ethereum Mainnet transfers are irreversible. Double-check the recipient address before confirming.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Review", action: review)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
            }
    }

    private func review() {
        let to = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard to.wholeMatch(of: /0x[0-9a-fA-F]{40}/) != nil else {
            wrong = .address
            return
        }
        guard let wei = Ether.wei(eth: amount.trimmingCharacters(in: .whitespaces)) else {
            wrong = .amount
            return
        }
        let plain = Locale(identifier: "en_US_POSIX")
        if let asked = Decimal(string: wei, locale: plain), let held = Decimal(string: balance, locale: plain), asked > held {
            wrong = .tooMuch
            return
        }
        wrong = nil
        open = false
        Task { await payer.quoteTransfer(to: to, wei: wei == balance ? "" : wei) }
    }
}

/// The deposit, as the payer and the chain show it: none, with the amount
/// to deposit, and, while the address holds no ETH, that ETH comes first;
/// on its way; held, with its balance, its expiry and Withdraw; being
/// withdrawn; closed on the chain. A deposit's quote under review takes the
/// amount's place.
private struct DepositSection: View {
    let payer: Payer
    @Bindable var settings: AppSettings
    @Binding var depositText: String

    var body: some View {
        Section("zkAPI Deposit") {
            if let stop = payer.stop, payer.stopTarget == .deposit || payer.stopTarget == .withdrawal {
                PressStopRow(payer: payer, stop: stop)
                    .id("v-stop-banner")
            }
            switch payer.state {
            case .none:
                LabeledContent("Active Deposit") {
                    HStack(spacing: 6) {
                        Text("$0.00")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        Text("· None yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(
                    payer.transferBlock == .nothingToTransfer
                        ? "Send ETH to your wallet above first, then deposit ETH here to unlock unlinkable one-time keys."
                        : "Moves ETH from your wallet above into the zkAPI vault. Chats spend from this deposit using fresh one-time keys, and unused ETH can be withdrawn back to your wallet anytime within 30 days."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                amount
            case .depositing(let stage):
                Moving(symbol: "arrow.down.circle", title: "Depositing", help: Self.stage(stage), hash: payer.funding?.transactionHash)
            case .ready, .settling:
                Held(payer: payer, settings: settings)
                amount
            case .withdrawing(let phase):
                Moving(
                    symbol: "arrow.up.circle", title: "Withdrawing", help: Self.phase(phase),
                    hash: payer.withdrawal?.transactionHash)
                if let destination = payer.withdrawal?.destination {
                    LabeledContent("To") {
                        Text(destination)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                // Signed again only from a new quote.
                if ["quoted", "waiting_settlement", "waiting_funds"].contains(phase) {
                    WithdrawRow(payer: payer, prominent: true)
                }
            case .taken:
                Text("This deposit was closed on the chain. Any ETH still in the wallet above can still be transferred out.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .unread, .failed:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var amount: some View {
        if let review = payer.review, case .deposit = review {
            ReviewRows(payer: payer, review: review)
        } else {
            Amount(payer: payer, text: $depositText)
        }
    }

    private static func stage(_ stage: String) -> String {
        switch stage {
        case "fee_wait": "Waiting for ETH for the fee."
        case "finalizing": "Waiting for final confirmation."
        case "activating": "Activating the deposit."
        default: "Submitted. Waiting for confirmation."
        }
    }

    private static func phase(_ phase: String) -> String {
        switch phase {
        case "waiting_settlement": "Waiting for the last request to settle."
        case "waiting_funds": "Waiting for ETH for the fee."
        case "confirming": "Confirming with the service."
        case "withdrawal_pending": "Submitted. Waiting for confirmation."
        default: "Quoted. Review it to withdraw."
        }
    }
}

/// A deposit or a withdrawal on its way: its symbol and title, its stage as
/// the help, and its transaction once there is one.
private struct Moving: View {
    let symbol: String
    let title: String
    let help: String
    let hash: String?

    var body: some View {
        LabeledContent {
            if let hash {
                Hash(hash)
            }
        } label: {
            Label(title, systemImage: symbol)
                .tip(help)
                .accessibilityHint(help)
        }
    }
}

/// The deposit held: its balance, whether a request is out or settling,
/// its expiry with the warning when it is near or past, and Withdraw.
private struct Held: View {
    let payer: Payer
    @Bindable var settings: AppSettings

    var body: some View {
        let queue = payer.queue
        TimelineView(.everyMinute) { context in
            let band = payer.band(at: context.date)
            LabeledContent {
                if let balance = payer.withdrawal?.privateBalance {
                    Text(Ether.text(gwei: balance))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
            } label: {
                let (symbol, words) =
                    if queue.held || (payer.state == .settling && !queue.sending) {
                        ("clock", "Settling the last request.")
                    } else if queue.sending {
                        ("arrow.up.circle", queue.waiting == 0 ? "1 sending" : "1 sending, \(queue.waiting) waiting")
                    } else {
                        ("checkmark.circle", "Ready")
                    }
                Label("Balance", systemImage: symbol)
                    .tip(words)
                    .accessibilityValue(words)
            }
            if let expiry = payer.expiry {
                LabeledContent {
                    Text(expiry.formatted(date: .abbreviated, time: .shortened))
                } label: {
                    HStack(spacing: 2) {
                        Text("Expires")
                        InfoButton("About Expiry", note: "After this date the service's operator can claim the deposit, spent or not. Cloak notifies you at days 20, 25, and 28 — withdraw before then.")
                    }
                }
                Toggle("Auto-withdraw 3 days before expiry", isOn: $settings.autoWithdrawBeforeExpiry)
                    .tip("Automatically withdraws unspent ETH back to your wallet 3 days before expiry while Cloak is open and running.")
                switch band {
                case .near?:
                    Label("Expires \(expiry.formatted(.dateTime.day().month())). Withdraw before then.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .due?:
                    Label("Expired. Withdraw now.", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                case .far?, nil:
                    EmptyView()
                }
            }
            WithdrawRow(payer: payer, prominent: band == .near || band == .due)
        }
    }
}

/// Withdraw: the whole deposit, to the payer's own address. Prominent when
/// the expiry is near or past. Its quote under review takes its place.
private struct WithdrawRow: View {
    let payer: Payer
    let prominent: Bool

    var body: some View {
        if let review = payer.review, case .withdrawal = review {
            ReviewRows(payer: payer, review: review)
        } else {
            let quoting = payer.activity == .quotingWithdrawal
            HStack(spacing: 8) {
                if quoting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching withdrawal quote over Tor…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let block = payer.withdrawBlock, !quoting {
                    Text(block.words)
                        .foregroundStyle(.secondary)
                }
                let withdraw = Button(quoting ? "Quoting…" : "Withdraw") { Task { await payer.quoteWithdrawal() } }
                    .tip("Returns the whole deposit to this wallet.")
                    .disabled(payer.withdrawBlock != nil || payer.activity != nil)
                if prominent {
                    withdraw.buttonStyle(.borderedProminent)
                } else {
                    withdraw
                }
            }
        }
    }
}

/// The amount to deposit, in dollars, which the payer prices in ETH, and
/// Deposit, which asks it for the quote. The amount is checked as Deposit
/// is pressed, and Return in the box does what Deposit does. Why an amount
/// was turned away shows until the text changes.
private struct Amount: View {
    let payer: Payer
    @Binding var text: String
    @State private var wrong = false

    var body: some View {
        let dollars = Self.dollars(text)
        LabeledContent("Amount") {
            HStack(spacing: 6) {
                ForEach(["5", "10", "20"], id: \.self) { preset in
                    Button("$\(preset)") {
                        text = preset
                        wrong = false
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(text == preset ? .accentColor : nil)
                }
                Text("$")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                TextField("Amount", text: $text, prompt: Text("10"))
                    .labelsHidden()
                    .accessibilityLabel("Deposit amount in US dollars")
                    .frame(width: 56)
                    .onSubmit {
                        // Nothing while Deposit is off or another wallet press is in flight.
                        if payer.depositBlock == nil && payer.activity == nil { deposit() }
                    }
                    .onChange(of: text) { wrong = false }
            }
        }
        Text("Start with $5–$10 ($5 unlocks up to Tier 25 models; $10+ gives room for multiple flagship turns). Beta · 30-day protocol limit: untouched zkAPI deposits expire after 30 days at the protocol layer and can be claimed by the operator — withdraw unused ETH before day 30. [Wallet security & 30-day limit](https://regents.sh/docs/cloak/wallets).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if wrong {
            Text("Enter an amount in dollars, like 10.")
                .foregroundStyle(.red)
        } else if let dollars, dollars > 50 {
            Text("Over $50. Deposit only what you'll spend.")
                .foregroundStyle(.orange)
        }
        let quoting = payer.activity == .quotingDeposit
        HStack(spacing: 8) {
            if quoting {
                ProgressView()
                    .controlSize(.small)
                Text("Fetching ETH quote over Tor…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let block = payer.depositBlock, !quoting {
                Text(block.words)
                    .foregroundStyle(.secondary)
            }
            Button(quoting ? "Quoting…" : "Get Deposit Quote", action: deposit)
                .tip("Shows what the deposit and Ethereum fee cost in ETH before anything is sent.")
                .disabled(payer.depositBlock != nil || payer.activity != nil)
        }
    }

    private func deposit() {
        guard let dollars = Self.dollars(text), dollars > 0, dollars <= 1_000_000 else {
            wrong = true
            return
        }
        wrong = false
        var micro = dollars * 1_000_000
        var whole = Decimal()
        NSDecimalRound(&whole, &micro, 0, .plain)
        let microUSD = NSDecimalNumber(decimal: whole).uint64Value
        Task { await payer.quoteDeposit(microUSD: microUSD) }
    }

    /// The dollars typed, with or without a dollar sign; nil when they do not
    /// read.
    private static func dollars(_ text: String) -> Decimal? {
        let typed = text.trimmingCharacters(in: .whitespaces).replacing("$", with: "")
        guard typed.wholeMatch(of: /[0-9]+(\.[0-9]{0,6})?/) != nil else { return nil }
        return Decimal(string: typed, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// A quote, as the payer made it, for its owner to confirm, as rows in the
/// section its press was made in: what it sends, where, the most it pays
/// in fees, and how long it holds (not counted down for a transfer). Its
/// button is the one place an approve
/// is sent from; once the quote has expired, the button asks for a new one,
/// shown before anything is approved.
private struct ReviewRows: View {
    let payer: Payer
    let review: Payer.Review

    var body: some View {
        let quote = review.quote
        Group {
            switch review {
            case .deposit(_, let microUSD):
                LabeledContent("Amount") {
                    Text((Decimal(quote.inputMicroUsd ?? microUSD) / 1_000_000).formatted(.currency(code: "USD")))
                }
                LabeledContent("Deposit", value: Ether.text(wei: quote.principalWei) ?? "—")
            case .withdrawal:
                LabeledContent("Amount", value: Ether.text(gwei: quote.amount))
            case .transfer:
                LabeledContent("Amount", value: Ether.text(wei: quote.principalWei) ?? "—")
            }
            if let destination = quote.destination {
                LabeledContent("To") {
                    Text(destination)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Fee", value: cost(wei: quote.requiredFeeWei).map { "Up to \($0)" } ?? "—")
            LabeledContent("Total", value: cost(wei: quote.requiredTotalWei) ?? "—")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let expired = quote.expired(at: context.date)
                let block = payer.confirmBlock(review)
                let busyQuoting = isQuoting
                let busyApproving = isApproving
                let busy = busyQuoting || busyApproving
                VStack(alignment: .leading, spacing: 8) {
                    if !busy, timed {
                        Text(
                            expired
                                ? "This 30-second quote expired before confirmation. Click New Quote to fetch a fresh ETH rate and fee."
                                : "Click \(title) before the timer runs out to sign and submit on Ethereum Mainnet."
                        )
                        .font(.caption)
                        .foregroundStyle(expired ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if !busy {
                        Text(
                            {
                                switch review {
                                case .deposit:
                                    return "Beta: irreversible Ethereum Mainnet deposit. Untouched zkAPI deposits expire after 30 days at the protocol layer — withdraw unused ETH before day 30."
                                case .transfer:
                                    return "Beta: irreversible Ethereum Mainnet transfer. Verify the recipient address and fee before confirming."
                                case .withdrawal:
                                    return "Beta: returns unspent ETH from your zkAPI deposit to your local ETH wallet on Ethereum Mainnet."
                                }
                            }()
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        if busyQuoting {
                            ProgressView()
                                .controlSize(.small)
                            Text("Refreshing quote over Tor…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if busyApproving {
                            ProgressView()
                                .controlSize(.small)
                            Text("Submitting on Ethereum over Tor…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if timed {
                            if !expired {
                                HStack(spacing: 4) {
                                    Text("Quote valid for")
                                        .foregroundStyle(.secondary)
                                    Text(quote.expires, style: .timer)
                                        .monospacedDigit()
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                }
                                .font(.callout)
                                .tip("Quotes hold for 30 seconds while ETH rate and gas are locked.")
                            } else {
                                Label("Quote expired", systemImage: "clock.badge.exclamationmark")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if let block, !busy {
                            Text(block.words)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Button("Cancel", action: payer.cancelReview)
                            .disabled(busyApproving)
                        Button(busyQuoting ? "Quoting…" : busyApproving ? "Submitting…" : (expired ? again : title)) {
                            Task { await payer.confirm() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || (!expired && block != nil))
                    }
                }
                .id("v-review-actions")
            }
        }
    }

    /// "0.0126 ETH", and in a deposit's review "0.0126 ETH, about $19.86":
    /// the fee can be several times a small deposit, and dollars say so.
    private func cost(wei: String) -> String? {
        guard let eth = Ether.text(wei: wei) else { return nil }
        guard let dollars = review.quote.dollars(wei: wei) else { return eth }
        return "\(eth), about \(dollars.formatted(.currency(code: "USD")))"
    }

    private var title: String {
        switch review {
        case .deposit: "Confirm Deposit"
        case .withdrawal: "Confirm Withdrawal"
        case .transfer: "Confirm Transfer"
        }
    }

    /// Whether the time the quote holds for is counted down beside the
    /// button. A deposit's and a withdrawal's are; a transfer's amount and
    /// address are its owner's own, and only its fee can change.
    private var timed: Bool {
        if case .transfer = review { false } else { true }
    }

    /// The button once the quote has expired: it asks for a new one, shown
    /// before anything is approved.
    private var again: String {
        timed ? "New Quote" : "Update Fee"
    }

    private var isQuoting: Bool {
        switch (review, payer.activity) {
        case (.deposit, .quotingDeposit), (.withdrawal, .quotingWithdrawal), (.transfer, .quotingTransfer): true
        default: false
        }
    }

    private var isApproving: Bool {
        switch (review, payer.activity) {
        case (.deposit, .approvingDeposit), (.withdrawal, .approvingWithdrawal), (.transfer, .approvingTransfer): true
        default: false
        }
    }
}

/// A phase or stage the Mac does not go on from: a triangle, a word, what
/// the payer named it on demand, and Try Again, which reads again and
/// makes the follow calls the payer allows.
private struct Failed: View {
    let payer: Payer
    let fault: String

    var body: some View {
        HStack(spacing: 8) {
            Label("Stopped", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .tip(fault)
                .accessibilityValue(fault)
            Spacer()
            Button("Try Again") { Task { await payer.retry() } }
        }
    }
}

/// The model V chats go to, from the service's list, each with its price a
/// million tokens where the provider lists one; which price is which, and
/// what is set aside for a request, is the row's help. The choice is kept in
/// Settings' defaults. A read of the list or of the prices that stops says
/// so in the row, with Try Again.
private struct ModelSection: View {
    let payer: Payer
    @Bindable var settings: AppSettings
    /// The last read of the list from here stopped; false while one is
    /// under way.
    @State private var stopped = false

    private struct DepositTier: Identifiable {
        let id: UInt64
        let holdLabel: String
        let depositLabel: String
        let tierLabel: String
        let examples: String
        let badge: String?
    }

    private static let depositTiers: [DepositTier] = [
        DepositTier(
            id: 4_500_000, holdLabel: "$4.50", depositLabel: "$5+", tierLabel: "Tier 25",
            examples: "Claude Fable 5.2, GPT-5.6 Terra Pro, GPT-5.6 Sol Pro", badge: "Best"),
        DepositTier(
            id: 3_000_000, holdLabel: "$3.00", depositLabel: "$3+", tierLabel: "Tier 5",
            examples: "Claude Opus 5.5, GPT-5.6 Sol, Qwen 3.8 Max Prime", badge: "Best"),
        DepositTier(
            id: 2_000_000, holdLabel: "$2.00", depositLabel: "$2+", tierLabel: "Tier 3",
            examples: "Claude Sonnet 5.5 (default), GPT-5.6 Terra, Grok 4.7", badge: nil),
        DepositTier(
            id: 1_000_000, holdLabel: "$1.00", depositLabel: "$1+", tierLabel: "Tier 1",
            examples: "Claude Haiku 5.5, GPT-5.6 Luna, Gemini 3.8 Flash, DeepSeek V4.1 Flash", badge: nil),
    ]

    var body: some View {
        Section {
            if let models = payer.models, let prices = payer.prices, let model = payer.model,
                let chosen = models.first(where: { $0.id == model })
            {
                let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
                let recommended = Payer.recommendedModels.compactMap { byID[$0] }
                let recommendedIDs = Set(recommended.map(\.id))
                let rest = models.filter { !recommendedIDs.contains($0.id) }
                let chosenHold = Self.hold(chosen.cap)
                let help =
                    "Prices per million tokens: in | out. Up to \(chosenHold) is temporarily held from your deposit while a turn runs; only actual tokens are spent and the rest stays in your deposit."
                Picker("Model", selection: Binding(get: { model }, set: { settings.vModel = $0 })) {
                    if !recommended.isEmpty {
                        Section("Recommended") {
                            ForEach(recommended) { item in
                                modelOption(item, prices: prices)
                            }
                        }
                        Section("All Models") {
                            ForEach(rest) { item in
                                modelOption(item, prices: prices)
                            }
                        }
                    } else {
                        ForEach(models) { item in
                            modelOption(item, prices: prices)
                        }
                    }
                }
                .tip(help)
                .accessibilityHint(help)

                Text("Temporarily holds up to \(chosenHold) per turn while running — only actual tokens are charged; unused funds stay in your deposit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                depositTierTable(selectedCap: chosen.cap)
            } else {
                LabeledContent("Model") {
                    if payer.models != nil, payer.prices != nil {
                        Text("None listed")
                            .foregroundStyle(.secondary)
                    } else if stopped {
                        HStack(spacing: 8) {
                            Text("Couldn't load the list")
                                .foregroundStyle(.secondary)
                            Button("Try Again") { Task { await load() } }
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                depositTierTable(selectedCap: nil)
            }
        } footer: {
            Text("A $5 deposit unlocks every model up through Tier 25 ($4.50 hold); $10+ gives room for multiple flagship turns. Powered by [Open Anonymity / zkAPI](https://zkapi.openanonymity.ai) ([GitHub](https://github.com/ethereum/zkapi) · [Vitalik's post](https://x.com/VitalikButerin/status/2111046730959433793)).")
                .foregroundStyle(.secondary)
        }
        .task(id: payer.state == .unread) {
            guard payer.state != .unread else { return }
            await load()
        }
    }

    @ViewBuilder
    private func modelOption(_ item: PayModel, prices: [String: PayPrice]) -> some View {
        let holdText = Self.hold(item.cap)
        if let price = prices[item.id]?.perMillion {
            let input = Self.price(price.input), output = Self.price(price.output)
            Text("\(item.id): \(input) | \(output) · \(holdText) hold")
                // Read aloud, a bar says nothing of which side is which.
                .accessibilityLabel("\(item.id), \(input) in, \(output) out, \(holdText) temporary hold")
                .tag(item.id)
        } else {
            Text("\(item.id) · \(holdText) hold")
                .accessibilityLabel("\(item.id), \(holdText) temporary hold")
                .tag(item.id)
        }
    }

    @ViewBuilder
    private func depositTierTable(selectedCap: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Deposit & Model Tiers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Deposit")
                        .frame(width: 44, alignment: .leading)
                    Text("Hold")
                        .frame(width: 44, alignment: .leading)
                    Text("What You Unlock")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)

                Divider()

                ForEach(Self.depositTiers) { tier in
                    let isSelected = selectedCap == tier.id
                    HStack(alignment: .top, spacing: 10) {
                        Text(tier.depositLabel)
                            .font(.caption.monospacedDigit().weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                            .frame(width: 44, alignment: .leading)
                        Text(tier.holdLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                if let badge = tier.badge {
                                    Text("\(tier.tierLabel) · \(badge)")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            Capsule().fill(
                                                isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.14)))
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                } else {
                                    Text(tier.tierLabel)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(tier.examples)
                                .font(.caption)
                                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.035)))
        }
        .padding(.top, 2)
    }

    /// Reads the service's models and their prices through the payer.
    private func load() async {
        stopped = false
        do {
            try await payer.loadModels()
            try await payer.loadPrices()
        } catch {
            stopped = true
        }
    }

    /// "$2.00" or "$4.50"
    private static func hold(_ capMicroUSD: UInt64) -> String {
        (Decimal(capMicroUSD) / 1_000_000).formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// "$0.27"
    private static func price(_ dollars: Decimal) -> String {
        dollars.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
    }
}

/// A transaction's hash, shortened, with Copy.
private struct Hash: View {
    let hash: String

    init(_ hash: String) {
        self.hash = hash
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(hash)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160)
                .textSelection(.enabled)
            CopyButton(text: hash)
        }
    }
}

/// Why a press in V's wallet stopped, in plain words, with Dismiss. One
/// that stopped for want of a read carries Try Again, which reads.
private struct PressStopRow: View {
    let payer: Payer
    let stop: Payer.Stop

    var body: some View {
        StopLine(title: stop.title, words: stop.words) {
            if stop == .unread {
                ReadAgain(payer: payer)
            }
            DismissButton(action: payer.dismiss)
        }
    }
}

/// Why the last read of V's wallet stopped, in plain words, with Try Again.
/// It stays until a read works.
private struct ReadStopRow: View {
    let payer: Payer
    let stop: PayStop

    var body: some View {
        StopLine(title: stop.title, words: stop.readWords) {
            ReadAgain(payer: payer)
        }
    }
}

/// Try Again on a read that stopped: reads now. A spinner in its place
/// while a read is under way.
private struct ReadAgain: View {
    let payer: Payer

    var body: some View {
        if payer.reading {
            ProgressView()
                .controlSize(.small)
        } else {
            Button("Try Again", action: payer.follow)
        }
    }
}

/// Why a chat request to V's payer stopped, in plain words. One with no
/// deposit says to deposit; that one, and one whose model the service can't
/// use, come with the way to the wallet.
struct PayStopRow: View {
    let stop: PayStop
    /// What the stopped request was to do: send or run.
    var verb = "send"
    var showWallet: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        let noDeposit = stop.code == .noDeposit
        StopLine(title: noDeposit ? "Deposit to \(verb)." : stop.title, words: noDeposit ? nil : stop.words) {
            if noDeposit || stop.code == .modelUnavailable, let showWallet {
                Button("Funds…", action: showWallet)
            }
            DismissButton(action: dismiss)
        }
    }
}

/// A stop's row: its mark, what stopped and what to do, and the ways on at
/// the right.
private struct StopLine<Actions: View>: View {
    let title: String
    let words: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                if let words {
                    Text(words)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            actions
        }
    }
}

/// Dismiss, as a symbol.
private struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button("Dismiss", systemImage: "xmark", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .hover(Circle(), outset: 4)
            .tip("Dismiss")
    }
}

extension Payer.Stop {
    var title: String {
        switch self {
        case .quote: "Couldn't get quote"
        case .approve(let stop): stop.code == .failed ? "Couldn't submit transaction" : stop.title
        case .unread: "Unavailable"
        }
    }

    /// What happened and what to do. A quote sends nothing, so one that got
    /// no answer says so; an approve may have been sent.
    var words: String {
        switch self {
        case .quote(let stop):
            if let reason = Self.specificDaemonReason(stop.detail) {
                return "Nothing was sent. \(reason)"
            } else if Self.looksLikeRPCUnavailable(stop.detail) {
                return "The Ethereum RPC was temporarily unreachable over Tor. Nothing was sent — wait a moment and try again."
            } else if stop.unanswered {
                return "No quote came back over Tor. Nothing was sent — try again."
            } else {
                return "Nothing was sent. \(stop.words)"
            }
        case .approve(let stop):
            let lower = stop.detail.lowercased()
            if lower.contains("expired") || (lower.contains("quote") && lower.contains("changed")) {
                return "That 30-second quote changed or expired before submission. Nothing was sent — request a new quote to try again."
            } else if let reason = Self.specificDaemonReason(stop.detail) {
                return reason
            } else if Self.looksLikeRPCUnavailable(stop.detail) {
                return "The Ethereum RPC was temporarily unreachable over Tor. Refresh in a moment to verify, then try again."
            } else if stop.unanswered {
                return "No answer came back over Tor. The transaction may have been sent — refresh in a moment to check."
            } else {
                return stop.words
            }
        case .unread:
            return "Cloak hasn't loaded your zkAPI deposit yet, so nothing was sent. Try again."
        }
    }

    /// Maps non-RPC daemon refusals (which the zkAPI admin API also returns as HTTP 502)
    /// into clear plain-English explanations instead of falsely blaming Ethereum RPC.
    private static func specificDaemonReason(_ detail: String) -> String? {
        let lower = detail.lowercased()
        if lower.contains("active deposit") || lower.contains("active note") || lower.contains("withdraw") && lower.contains("before") {
            return "Withdraw your active zkAPI deposit before transferring ETH out of this wallet."
        }
        if lower.contains("pending") && (lower.contains("transaction") || lower.contains("return") || lower.contains("deposit") || lower.contains("withdrawal") || lower.contains("settlement")) {
            return "Wait for your pending transaction or settlement to finish, then try again."
        }
        if lower.contains("insufficient") || lower.contains("shortfall") || lower.contains("exceeds balance") || lower.contains("not enough") {
            return "Not enough ETH in this wallet to cover the amount plus Ethereum Mainnet gas fees."
        }
        if lower.contains("contract") && lower.contains("address") {
            return "Transfers to contract addresses aren't supported here. Enter a standard Ethereum (EOA) address."
        }
        if lower.contains("self") || lower.contains("same address") || lower.contains("funding address") && lower.contains("destination") {
            return "Destination address can't be the same as this Cloak wallet."
        }
        if lower.contains("revert") || lower.contains("simulation") {
            return "Transaction simulation reverted on Ethereum Mainnet. Check the balance, address, and deposit status."
        }
        if lower.contains("paused") {
            return "Deposits and withdrawals are temporarily paused by the zkAPI operator."
        }
        return nil
    }

    private static func looksLikeRPCUnavailable(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        return lower.contains("payment rpc unavailable")
            || lower.contains("dial tcp")
            || lower.contains("context deadline exceeded")
            || lower.contains("connection refused")
            || lower.contains("eof")
            || lower.contains("502 bad gateway")
            || lower.contains("503")
            || lower.contains("504")
    }
}

extension PayStop {
    var title: String {
        switch code {
        case .unreachable: "Unreachable"
        case .noDeposit: "No deposit"
        case .withdrawing: "Withdrawing"
        case .busy: "Busy"
        case .modelUnavailable: "Model unavailable"
        case .torDown: "Tor down"
        case .refused: "Declined"
        case .providerFailed: "Failed"
        case .answerRefused: "No answer"
        case .heldTooLong: "Settling"
        case .timedOut: "No answer"
        case .ended: "Interrupted"
        case .cancelled: "Stopped"
        case .failed: "Couldn't complete"
        }
    }

    /// For a read of the zkAPI ETH wallet. A read sends nothing, so one that got no
    /// answer says so.
    var readWords: String {
        switch code {
        case .timedOut, .ended, .providerFailed:
            "Couldn't load your zkAPI ETH wallet over Tor. Nothing was sent — try again."
        case .failed:
            "Couldn't load your zkAPI Ethereum balance or deposit status over Tor. Wait a moment and try again."
        default:
            words
        }
    }

    /// No answer came: in time, before the connection ended, or from the
    /// provider.
    fileprivate var unanswered: Bool {
        switch code {
        case .timedOut, .ended, .providerFailed: true
        default: false
        }
    }

    /// What happened and what to do, for a chat request.
    var words: String {
        switch code {
        case .unreachable: "Couldn't reach the zkAPI payment service. Pause and start Cloak, then try again."
        case .noDeposit: "Make a deposit in Funds, then try again."
        case .withdrawing: "The deposit is being withdrawn, so it can't pay for requests now."
        case .busy: "zkAPI Anon Inference is busy with another request. Try again in a moment."
        case .modelUnavailable: "The service can't use this model now. Pick another in Funds."
        case .torDown: "Cloak couldn't reach the service through Tor. Try again."
        case .refused: "The service declined the request."
        case .providerFailed: "The provider failed. The request may have been paid for."
        case .answerRefused: "The model declined to answer."
        case .heldTooLong: "The last request is still settling, so nothing was sent. Try again in a minute."
        case .timedOut: "No answer came in time. The request may have been paid for."
        case .ended: "The connection ended before the answer. The request may have been paid for."
        case .cancelled: "The request was stopped."
        case .failed: "zkAPI Anon Inference couldn't complete this over Tor. Wait a moment and try again."
        }
    }
}

extension Payer.Block {
    var words: String {
        switch self {
        case .paused: "Paused by operator"
        case .oneAtATime: "One deposit at a time"
        case .nothingToWithdraw: "Nothing to withdraw"
        case .needs(let wei): "Insufficient balance: \(Ether.text(Decimal(sign: .plus, exponent: -18, significand: wei), up: true)) more needed"
        case .needsFee: "Insufficient ETH for the fee"
        case .nothingToTransfer: "Nothing to transfer"
        case .activeDeposit: "Withdraw active deposit first"
        case .pendingTransaction: "Transaction pending"
        }
    }
}

/// Amounts of ETH as the payer gives them, in wei or gwei, written in ETH.
enum Ether {
    /// "0.0123 ETH", from wei as a decimal string; nil when it does not read.
    static func text(wei: String) -> String? {
        guard let wei = Decimal(string: wei, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return text(Decimal(sign: .plus, exponent: -18, significand: wei))
    }

    static func text(gwei: UInt64) -> String {
        text(Decimal(sign: .plus, exponent: -9, significand: Decimal(gwei)))
    }

    /// ETH in full from wei as a decimal string, "0.01", as an amount field
    /// takes it; nil when it does not read.
    static func exact(wei: String) -> String? {
        guard wei.wholeMatch(of: /[0-9]+/) != nil else { return nil }
        let digits = String(repeating: "0", count: max(0, 19 - wei.count)) + wei
        let whole = digits.dropLast(18).drop { $0 == "0" }
        let fraction = String(digits.suffix(18)).replacing(/0+$/, with: "")
        return (whole.isEmpty ? "0" : String(whole)) + (fraction.isEmpty ? "" : "." + fraction)
    }

    /// Wei as a decimal string from ETH as typed, "0.01" or ".5"; nil when
    /// it is not an amount above zero of at most 18 decimals.
    static func wei(eth typed: String) -> String? {
        guard let match = typed.wholeMatch(of: /([0-9]*)(?:\.([0-9]{0,18}))?/) else { return nil }
        let fraction = String(match.2 ?? "")
        let digits = (match.1 + fraction + String(repeating: "0", count: 18 - fraction.count)).drop { $0 == "0" }
        return digits.isEmpty ? nil : String(digits)
    }

    /// Up to six decimals, rounded up when `up`, for an amount still needed.
    static func text(_ eth: Decimal, up: Bool = false) -> String {
        let format = Decimal.FormatStyle.number.precision(.fractionLength(0...6))
        return "\(eth.formatted(up ? format.rounded(rule: .up) : format)) ETH"
    }
}
