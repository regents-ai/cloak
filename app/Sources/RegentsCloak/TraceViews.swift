import AppKit
import CloakChat
import SwiftUI

// Trace sharing's screens (`TraceShare`): the Share Traces section of
// NEAR's Wallet sheet, the share control at the foot of a NEAR chat, the
// sheets that ready a chat and review it, and each shared trace's status
// line. Every press reaches the model; a control is off only where its
// press is certain to fail, with a few words beside it saying why.

/// The commons' terms, as its own client links them.
private let terms = URL(string: "https://tracecommons.ai/about/tnc/")!

/// The Share Traces switch, and while it is on, the account and the
/// choices: Debugging always granted, the other four off until granted,
/// each for chats readied from then on. The terms are a press away.
struct TraceSharing: View {
    @Bindable var settings: AppSettings
    let share: TraceShare
    let route: NearRoute?

    var body: some View {
        Section {
            Toggle("Share Traces", isOn: $settings.shareTraces)
            if share.state != .off {
                LabeledContent("Account") {
                    HStack(spacing: 6) {
                        account
                    }
                }
                if let stop = share.stop, [.open, .signIn, .keep].contains(stop.step) {
                    TraceStopRow(stop: stop.stop) { share.stop = nil }
                }
            }
            if case .signedIn = share.state {
                ForEach(TraceScope.allCases) { scope in
                    if scope == .debuggingEvaluation {
                        LabeledContent(scope.title) {
                            Text("Always")
                        }
                        .help(scope.about)
                    } else {
                        Toggle(scope.title, isOn: Binding(get: { share.scopes.contains(scope) }, set: { share.grant(scope, $0) }))
                            .help(scope.about)
                    }
                }
                LabeledContent("Terms") {
                    Link("Open", destination: terms)
                }
            }
        } footer: {
            Text("Shares a NEAR chat with [Trace Commons](https://tracecommons.ai) only when you ready it, review it and press Share.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var account: some View {
        switch share.state {
        case .off:
            EmptyView()
        case .opening:
            // The stop under it says why.
            if let stop = share.stop, stop.step == .open {
                SymbolButton("Try Again", symbol: "arrow.clockwise") { Task { await share.turn(on: true) } }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .signedOut:
            torBlock
            SignInMenu(share: share, route: route)
        case .signingIn:
            ProgressView()
                .controlSize(.small)
            Text("In your browser")
                .foregroundStyle(.secondary)
            SymbolButton("Cancel", symbol: "xmark") { share.cancelSignIn() }
        case .signedIn:
            torBlock
            if let provider = share.provider {
                Text(provider.title)
            }
            SignInMenu(share: share, route: route, again: true)
        }
    }

    /// Why Sign In is off, when it is.
    @ViewBuilder private var torBlock: some View {
        if route == nil {
            Text("Tor needs Cloak running.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Sign In, by GitHub or Google, in the browser. Off while Tor is on and
/// Cloak is not running, since every step goes on NEAR mode's route.
private struct SignInMenu: View {
    let share: TraceShare
    let route: NearRoute?
    var again = false

    var body: some View {
        Menu {
            ForEach(TraceProvider.allCases) { provider in
                Button(provider.title) {
                    guard let route else { return }
                    Task { await share.signIn(with: provider, route: route) { _ = NSWorkspace.shared.open($0) } }
                }
            }
        } label: {
            if again {
                Label("Sign In", systemImage: "person.crop.circle")
                    .labelStyle(.iconOnly)
            } else {
                Text("Sign In")
            }
        }
        .menuIndicator(again ? .hidden : .automatic)
        .menuStyle(.button)
        .fixedSize()
        .help("Sign In")
        .disabled(route == nil)
    }
}

/// The share control at the foot of a NEAR chat: Share, which opens the
/// sheet that readies the chat; once readied, that the next message shares,
/// or that its time ran out, with Ready Again; once answered, Review, which
/// opens the review sheet, off with "No receipt" when NEAR gave none. Off
/// with "Sign in to share" until signed in, and dimmed while Share Traces
/// is off, when a press says so. Never hidden.
struct ShareControl: View {
    let share: TraceShare
    let route: NearRoute?
    let conversation: Conversation
    @State private var readying = false
    @State private var reviewing = false
    @State private var explaining = false

    var body: some View {
        HStack(spacing: 4) {
            switch share.state {
            case .off:
                SymbolButton("Share", symbol: "square.and.arrow.up") { explaining = true }
                    .foregroundStyle(.tertiary)
                    .accessibilityHint("Share Traces is off.")
                    .popover(isPresented: $explaining, arrowEdge: .top) {
                        Text("Share Traces is off. Turn it on in Wallet.")
                            .font(.callout)
                            .padding(12)
                    }
            case .opening:
                SymbolButton("Share", symbol: "square.and.arrow.up") {}
                    .disabled(true)
                if let stop = share.stop, stop.step == .open {
                    Text(stop.stop.shareTitle)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            case .signedOut, .signingIn:
                SymbolButton("Share", symbol: "square.and.arrow.up") {}
                    .disabled(true)
                Text("Sign in to share")
                    .foregroundStyle(.secondary)
            case .signedIn(let sharing):
                signedIn(sharing)
            }
        }
        .sheet(isPresented: $readying) {
            ReadySheet(share: share, route: route, conversation: conversation)
        }
        .sheet(isPresented: $reviewing) {
            ReviewSheet(share: share, route: route, chat: conversation.id)
        }
    }

    @ViewBuilder private func signedIn(_ sharing: TraceShare.Sharing) -> some View {
        let chat = conversation.id
        switch sharing {
        case .readied(let readied) where readied.chat == chat:
            // Each second, so it turns within one of the challenge ending,
            // as the next message stops going readied.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 4) {
                    if readied.expires > context.date {
                        SymbolButton("Share", symbol: "square.and.arrow.up") { readying = true }
                            .foregroundStyle(.tint)
                        Text("Next message shares")
                            .foregroundStyle(.secondary)
                            .help(
                                "Your next message here goes without end-to-end encryption, until \(readied.expires.formatted(date: .omitted, time: .shortened))."
                            )
                    } else {
                        SymbolButton("Share", symbol: "square.and.arrow.up") {}
                            .disabled(true)
                        Text("Time ran out")
                            .foregroundStyle(.secondary)
                        SymbolButton("Ready Again", symbol: "arrow.clockwise") { readying = true }
                    }
                }
            }
        case .sending(let readied, _) where readied.chat == chat:
            ProgressView()
                .controlSize(.small)
                .help("Sharing this message")
        case .answered(let answered) where answered.readied.chat == chat:
            if answered.exchange.hasReceipt {
                SymbolButton("Review", symbol: "doc.text.magnifyingglass") { reviewing = true }
                    .foregroundStyle(.tint)
            } else {
                SymbolButton("Review", symbol: "doc.text.magnifyingglass") {}
                    .disabled(true)
                Text("No receipt")
                    .foregroundStyle(.secondary)
                    .help(answered.exchange.noReceipt ?? "")
                SymbolButton("Ready Again", symbol: "arrow.clockwise") { readying = true }
            }
        case .reviewed(let answered, _) where answered.readied.chat == chat:
            SymbolButton("Review", symbol: "doc.text.magnifyingglass") { reviewing = true }
                .foregroundStyle(.tint)
        default:
            SymbolButton("Share", symbol: "square.and.arrow.up") { readying = true }
        }
    }
}

/// Readies a chat: says what the next message costs, which uses are
/// granted, and links the terms. Ready gets the commons' challenge, after
/// which the sheet closes.
private struct ReadySheet: View {
    let share: TraceShare
    let route: NearRoute?
    let conversation: Conversation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share")
                .font(.title2.weight(.semibold))
            Text(
                "Your next message in this chat goes to NEAR without end-to-end encryption. Then Review sends the chat to the commons for redaction, and shows you what would be shared."
            )
            .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Uses")
                        .foregroundStyle(.secondary)
                    Text(share.granted.map(\.title).formatted(.list(type: .and)))
                }
                GridRow {
                    Text("Terms")
                        .foregroundStyle(.secondary)
                    Link("Open", destination: terms)
                }
            }
            if let other = share.chat, other != conversation.id {
                Text("The chat readied before stops sharing.")
                    .foregroundStyle(.secondary)
            }
            if let stop = share.stop, stop.step == .ready, stop.chat == conversation.id {
                TraceStopRow(stop: stop.stop) { share.stop = nil }
            }
            HStack(spacing: 10) {
                if share.isBusy(.ready) {
                    ProgressView()
                        .controlSize(.small)
                }
                if route == nil {
                    Text("Tor needs Cloak running.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Ready") {
                    guard let route else { return }
                    Task {
                        await share.ready(conversation, route: route)
                        if case .signedIn(.readied(let readied)) = share.state, readied.chat == conversation.id { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(route == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// The review: Before, the exchange as it went to NEAR and came back, and
/// After, the witness's envelope exactly as it came. Review sends the chat
/// to the witness; Share uploads exactly the After shown, after which the
/// sheet closes.
private struct ReviewSheet: View {
    let share: TraceShare
    let route: NearRoute?
    let chat: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let answered = share.answered.flatMap { $0.readied.chat == chat ? $0 : nil }
        let reviewed: TraceReview? =
            if case .signedIn(.reviewed(let reviewedFor, let review)) = share.state, reviewedFor == answered { review } else { nil }
        VStack(alignment: .leading, spacing: 16) {
            Text("Review")
                .font(.title2.weight(.semibold))
            if let answered {
                if reviewed == nil {
                    Text("Review sends this chat to the commons' witness, which redacts it. Nothing is shared until you press Share.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 12) {
                    Pane(title: "Before", count: nil, mark: .removed) {
                        TextBox(text: .constant(Self.before(answered.exchange)), label: "Before", editable: false, maxHeight: 420)
                    }
                    Pane(title: "After", count: nil, mark: .added) {
                        if let reviewed {
                            TextBox(text: .constant(String(decoding: reviewed.envelope, as: UTF8.self)), label: "After", editable: false, maxHeight: 420)
                        } else {
                            Text("Not reviewed yet")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 60)
                        }
                    }
                }
            } else {
                Text("This chat has no message to review now.")
                    .foregroundStyle(.secondary)
            }
            if let stop = share.stop, [.review, .share].contains(stop.step), stop.chat == chat {
                TraceStopRow(stop: stop.stop) { share.stop = nil }
            }
            HStack(spacing: 10) {
                if share.isBusy(.review) || share.isBusy(.share) {
                    ProgressView()
                        .controlSize(.small)
                }
                if route == nil {
                    Text("Tor needs Cloak running.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if reviewed != nil {
                    Button("Review") { press { await share.review(route: $0) } }
                        .disabled(route == nil)
                    Button("Share") {
                        press { route in
                            await share.share(route: route)
                            if share.answered == nil { dismiss() }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(route == nil)
                } else {
                    Button("Review") { press { await share.review(route: $0) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(route == nil || answered == nil)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 300)
    }

    private func press(_ step: @escaping @MainActor (NearRoute) async -> Void) {
        guard let route else { return }
        Task { await step(route) }
    }

    /// The request as it went to NEAR, then the reply as it came.
    private static func before(_ exchange: TraceExchange) -> String {
        String(decoding: exchange.request, as: UTF8.self) + "\n\n" + String(decoding: exchange.response, as: UTF8.self)
    }
}

/// Each trace shared from one message: the commons' status as it last
/// reported it, the credit only when it reported some, Refresh, and while
/// the trace is still held, Withdraw, asked first.
struct TraceStatusRows: View {
    let share: TraceShare
    let route: NearRoute?
    let chat: UUID
    let turn: UUID

    var body: some View {
        ForEach(share.shared(in: chat).filter { $0.turn == turn }) { trace in
            TraceStatusRow(share: share, route: route, trace: trace)
        }
    }
}

private struct TraceStatusRow: View {
    let share: TraceShare
    let route: NearRoute?
    let trace: SharedTrace
    @State private var confirming = false

    var body: some View {
        // Traces show only once signed in, so the one other state here is a
        // sign-in again, which holds the sharing helper.
        let block: String? =
            if case .signedIn = share.state { route == nil ? "Tor needs Cloak running." : nil } else { "Finish signing in" }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(trace.word, systemImage: "square.and.arrow.up")
                    .help(trace.about)
                if let credit = trace.credit {
                    Text(credit)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if share.isBusy(.refresh) || share.isBusy(.withdraw) {
                    ProgressView()
                        .controlSize(.small)
                }
                if let block {
                    Text(block)
                        .foregroundStyle(.secondary)
                }
                SymbolButton("Refresh", symbol: "arrow.clockwise") {
                    guard let route else { return }
                    Task { await share.refresh(trace, route: route) }
                }
                .disabled(block != nil)
                if trace.withdrawable {
                    SymbolButton("Withdraw", symbol: "arrow.uturn.backward") { confirming = true }
                        .disabled(block != nil)
                }
            }
            if let stop = share.stop, [.refresh, .withdraw].contains(stop.step), stop.trace == trace.submission {
                TraceStopRow(stop: stop.stop) { share.stop = nil }
                if stop.step == .withdraw, stop.stop.kind == .status, stop.stop.code == 401 || stop.stop.code == 403 {
                    HStack(spacing: 6) {
                        Text("Sign in again, then withdraw.")
                            .foregroundStyle(.secondary)
                        SignInMenu(share: share, route: route)
                    }
                }
            }
        }
        .font(.callout)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .confirmationDialog("Withdraw", isPresented: $confirming, titleVisibility: .visible) {
            Button("Withdraw", role: .destructive) {
                guard let route else { return }
                Task { await share.withdraw(trace, route: route) }
            }
        } message: {
            Text("The commons deletes it. Copies already in a published export can't be recalled, and credit still pending is lost.")
        }
    }
}

/// A sharing step that stopped: its few words, what it means, and whether
/// anything may have gone.
private struct TraceStopRow: View {
    let stop: NearStop
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.shareTitle)
                    .fontWeight(.medium)
                Text(stop.shareWords)
                    .foregroundStyle(.secondary)
                // The keychain's stops are this Mac's alone, and a status
                // is the host turning the step down.
                if stop.kind != .key, stop.kind != .status {
                    Text(stop.sent ? "It may have arrived." : "Nothing was sent.")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hover(Circle(), outset: 4)
                .help("Dismiss")
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension TraceScope {
    var title: String {
        switch self {
        case .debuggingEvaluation: "Debugging"
        case .benchmarkOnly: "Benchmarks"
        case .rankingTraining: "Ranking"
        case .modelTraining: "Training"
        case .publicAttribution: "Attribution"
        }
    }

    var about: String {
        switch self {
        case .debuggingEvaluation: "Always granted. The commons may use shared chats to find faults and to evaluate models."
        case .benchmarkOnly: "The commons may make benchmarks from shared chats."
        case .rankingTraining: "The commons may train ranking models on shared chats."
        case .modelTraining: "The commons may train models on shared chats."
        case .publicAttribution: "The commons may link your traces to a public name."
        }
    }
}

extension TraceProvider {
    var title: String {
        switch self {
        case .github: "GitHub"
        case .google: "Google"
        }
    }
}

extension SharedTrace {
    /// The commons' status in a word or two; one Cloak has no words for, as
    /// the commons wrote it.
    var word: String {
        switch status {
        case "submitted", "processing": "Sent"
        case "quarantined", "awaiting_pii_backstop": "In review"
        case "accepted": "Accepted"
        case "rejected": "Not accepted"
        case "revoked", "withdrawn": "Withdrawn"
        default: status.replacing("_", with: " ").capitalized
        }
    }

    /// When it was shared, and once withdrawn, whether copies had gone.
    var about: String {
        let when = "Shared \(shared.formatted(date: .abbreviated, time: .shortened))."
        return reach == "commons_distributed" ? when + " Copies already in a published export can't be recalled." : when
    }

    /// The credit the commons reported: final once it is, else pending; nil
    /// while it reported none.
    var credit: String? {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        if let final, final > 0 { return "Credit \(final.formatted(format))" }
        if let pending, pending > 0 { return "Pending \(pending.formatted(format))" }
        return nil
    }

    /// Whether the commons still holds it, so Withdraw can take it back.
    var withdrawable: Bool {
        !["revoked", "withdrawn", "expired", "purged"].contains(status)
    }
}

extension NearStop {
    /// A sharing step's stop, in a word or two.
    var shareTitle: String {
        switch kind {
        case .line: "Cloak error"
        case .request: "Can't share"
        case .signin: "Not signed in"
        case .fetch: "No answer"
        case .claim: "No claim"
        case .refused: "Witness refused"
        case .connect: "No connection"
        case .pin: "Server changed"
        case .send: "Interrupted"
        case .status:
            switch code {
            case 401, 403: "Sign in again"
            case 429: "Too many"
            default: "Refused"
            }
        case .reply: "Answer refused"
        case .helper: "Damaged"
        case .ended: "Stopped"
        case .key: "Keychain unreadable"
        }
    }

    var shareWords: String {
        switch kind {
        case .line: "Cloak's request wasn't formed right."
        case .request: "This step can't go as it is."
        case .signin: "The sign-in in your browser didn't finish."
        case .fetch: "Cloak couldn't fetch what this step needs. Try again."
        case .claim: "The commons didn't give Cloak a claim to go with."
        case .refused: "The commons' witness didn't pass Cloak's check, so nothing was sent to it."
        case .connect: "Cloak couldn't connect."
        case .pin: "The server changed between the check and the request."
        case .send: "The connection dropped before the answer came."
        case .status:
            switch code {
            case 401, 403: "The commons didn't accept your sign-in."
            case 429: "The commons is limiting requests. Wait, then try again."
            default: "The commons answered with error \(code ?? 0)."
            }
        case .reply: "The answer didn't read, so it isn't used."
        case .helper: "Reinstall Cloak."
        case .ended: "The part of Cloak that shares quit."
        case .key: "The keychain didn't give Cloak what sharing keeps."
        }
    }
}
