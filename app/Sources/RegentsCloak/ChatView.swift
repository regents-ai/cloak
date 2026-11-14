import AppKit
import CloakChat
import CloakControl
import CloakSupervisor
import SwiftUI

/// The Chat window: conversations on the left, newest first; the one shown
/// on the right, each message as written and as reworded, side by side, and
/// its answer once sent, with the box to write the next one at the bottom.
/// Development mode's mark is always at the top.
struct ChatView: View {
    @Bindable var chat: Chat

    static func window(_ chat: Chat) -> NSWindow {
        let window = ClosingWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Chat"
        // Escape cancels a rewording here.
        window.closesOnEscape = false
        let content = NSHostingController(rootView: ChatView(chat: chat))
        content.sceneBridgingOptions = [.toolbars]
        content.sizingOptions = [.minSize]
        window.contentViewController = content
        window.setContentSize(NSSize(width: 980, height: 660))
        return window
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(chat: chat)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            Detail(chat: chat)
        }
        .frame(minWidth: 760, minHeight: 460)
        .task { await chat.open() }
    }
}

private struct Sidebar: View {
    @Bindable var chat: Chat
    @State private var deleting: Conversation?

    var body: some View {
        List(selection: $chat.selection) {
            ForEach(chat.conversations) { conversation in
                Text(conversation.title)
                    .lineLimit(1)
                    .tag(conversation.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { deleting = conversation }
                    }
            }
            ForEach(chat.unreadable, id: \.self) { id in
                Label("Can't open", systemImage: "lock")
                    .foregroundStyle(.secondary)
                    .tag(id)
            }
        }
        .onDeleteCommand { deleting = chat.selected }
        .toolbar {
            ToolbarItem {
                Button("New", systemImage: "square.and.pencil") { chat.newConversation() }
                    .keyboardShortcut("n")
                    .help("New")
                    .disabled(!chat.canCompose)
            }
            ToolbarItem {
                Button("Delete", systemImage: "trash") { deleting = chat.selected }
                    .help("Delete")
                    .disabled(chat.selected?.turns.isEmpty ?? true)
            }
        }
        .confirmationDialog(
            "Delete chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { conversation in
            Button("Delete", role: .destructive) { chat.delete(conversation.id) }
        } message: { _ in
            Text("It's removed from this Mac and can't be brought back.")
        }
    }
}

private struct Detail: View {
    @Bindable var chat: Chat
    @State private var showingWallet = false

    var body: some View {
        VStack(spacing: 0) {
            DevelopmentBar()
            Divider()
            content
        }
        .toolbar {
            ToolbarItem {
                Button("Wallet", systemImage: "creditcard") { showingWallet = true }
                    .help("Wallet")
                    .disabled(!chat.isOpen)
            }
        }
        .sheet(isPresented: $showingWallet) { WalletView(wallet: chat.wallet) }
        .task(id: chat.supervisor.phase == .running) { await chat.wallet.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch chat.access {
        case .opening:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missingKey:
            ContentUnavailableView(
                "Locked", systemImage: "lock",
                description: Text("The key to your saved chats is missing from this Mac's keychain, so they can't be opened. They're kept as they are."))
        case .failed:
            ContentUnavailableView {
                Label("Can't open", systemImage: "lock")
            } description: {
                Text("Your saved chats couldn't be opened. The keychain may have said no.")
            } actions: {
                Button("Retry") { Task { await chat.open() } }
            }
        case .open:
            if let conversation = chat.selected {
                VStack(spacing: 0) {
                    Turns(chat: chat, conversation: conversation)
                    Divider()
                    Compose(chat: chat)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                ContentUnavailableView(
                    "Can't open", systemImage: "lock",
                    description: Text("This chat's file didn't open. It's kept as it is."))
            }
        }
    }
}

/// The conversation's messages, oldest first. Only the newest can be edited,
/// reworded again or sent, until it is sent.
private struct Turns: View {
    let chat: Chat
    let conversation: Conversation

    var body: some View {
        let rewording = chat.rewording?.conversation == conversation.id ? chat.rewording : nil
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if conversation.turns.isEmpty, rewording == nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("New chat")
                                .font(.title3.weight(.semibold))
                            Text("Each message is reworded on this Mac first. You see both, can edit the reworded one, and send it.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    }
                    ForEach(conversation.turns) { turn in
                        TurnCard(
                            chat: chat, conversation: conversation.id, turn: turn,
                            newest: turn.id == conversation.turns.last?.id,
                            rewording: rewording.flatMap { $0.turn == turn.id ? $0 : nil })
                    }
                    if let rewording, rewording.turn == nil {
                        PendingCard(chat: chat, rewording: rewording)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(conversation.id)
            }
            // Reads from the top; a long chat opens at its newest message.
            // While the end is in view it stays in view as messages are added
            // or the window changes size. The anchor does that, except when a
            // chat that fit stops fitting, so the end is brought back here.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
                let resized = new.contentSize != old.contentSize || new.containerSize != old.containerSize
                if resized, old.visibleRect.maxY >= old.contentSize.height - 1 {
                    proxy.scrollTo(conversation.id, anchor: .bottom)
                }
            }
        }
        // A scroll view of its own for each chat, so one read part way up
        // leaves the next opening at its newest message too.
        .id(conversation.id)
    }
}

/// One message: Original and Reworded side by side, the words taken out
/// marked in one, the words put in marked in the other, then its answer.
/// The newest unanswered one has the lights and Send: nothing is sent unless
/// it is reworded and Cloak routes it through Tor, and Unlinked is never
/// good in Development mode.
private struct TurnCard: View {
    let chat: Chat
    let conversation: UUID
    let turn: Turn
    let newest: Bool
    let rewording: Chat.Rewording?

    var body: some View {
        let diff = WordDiff(original: turn.original, reworded: turn.reworded)
        let sending = chat.sending[turn.id]
        let open = newest && turn.answer == nil
        Card {
            HStack(alignment: .top, spacing: 12) {
                Pane(title: "Original", count: diff.removed.count, mark: .removed) {
                    TextBox(text: .constant(turn.original), label: "Original", editable: false, marks: diff.removed, mark: .removed)
                }
                Pane(title: "Reworded", count: diff.added.count, mark: .added) {
                    TextBox(
                        text: open
                            ? Binding(get: { turn.reworded }, set: { chat.edit(turn.id, in: conversation, to: $0) })
                            : .constant(turn.reworded),
                        label: "Reworded", editable: open && sending == nil && chat.rewording == nil, marks: diff.added,
                        mark: .added)
                }
            }
            if let answer = turn.answer {
                Pane(title: "Answer", count: nil, mark: .added) {
                    TextBox(text: .constant(answer), label: "Answer", editable: false)
                }
            }
            if let stop = chat.sendStop, stop.turn == turn.id {
                StopRow(stop: stop.stop) { chat.sendStop = nil }
                    .padding(12)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            if let rewording {
                Progress(chat: chat, started: rewording.started)
            } else if open {
                Lights(reworded: !Chat.isBlank(turn.reworded), routed: chat.supervisor.phase == .running)
                HStack(spacing: 12) {
                    Button("Reword", systemImage: "arrow.clockwise") { chat.reword(turn, in: conversation) }
                        .disabled(!chat.canReword || sending != nil)
                    if let sending {
                        SendingProgress(started: sending.started)
                    }
                    Spacer()
                    let block = chat.sendBlock(turn)
                    if let block {
                        Text(block)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    // Each press sends, one under way or not.
                    Button("Send") { chat.send(turn.id, in: conversation) }
                        .buttonStyle(.borderedProminent)
                        .disabled(block != nil)
                }
            } else if let sending {
                SendingProgress(started: sending.started)
            }
        }
    }
}

/// Whether the message is reworded, routed through Tor and unlinked from
/// the person's other chats.
private struct Lights: View {
    let reworded: Bool
    let routed: Bool

    var body: some View {
        HStack(spacing: 16) {
            Light(title: "Reworded", good: reworded)
            Light(title: "Routed", good: routed)
            Light(title: "Unlinked", good: false)
                .help("The provider can link your chats, because one wallet pays for all of them.")
        }
        .font(.callout)
    }
}

private struct Light: View {
    let title: String
    let good: Bool

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: good ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(good ? .green : .orange)
        }
        .accessibilityValue(good ? "Good" : "Not good")
    }
}

private struct SendingProgress: View {
    let started: Date

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Sending")
            Text(timerInterval: started...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A new message while it is being reworded.
private struct PendingCard: View {
    let chat: Chat
    let rewording: Chat.Rewording

    var body: some View {
        Card {
            Pane(title: "Original", count: nil, mark: .removed) {
                TextBox(text: .constant(rewording.original), label: "Original", editable: false)
            }
            Progress(chat: chat, started: rewording.started)
        }
    }
}

private struct Progress: View {
    let chat: Chat
    let started: Date

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Rewording")
            Text(timerInterval: started...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: chat.cancel)
                .keyboardShortcut(.cancelAction)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}

/// A titled text, with how many words are marked and how they look.
private struct Pane<Content: View>: View {
    let title: String
    let count: Int?
    let mark: TextBox.Mark
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let count {
                    Text(mark == .removed ? "\(count) removed" : "\(count) added")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(nsColor: mark.tint).opacity(0.15), in: Capsule())
                }
            }
            content
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The box for the next message, what stopped the last rewording, and,
/// unless Cloak is running, why rewording waits and a Start button.
private struct Compose: View {
    @Bindable var chat: Chat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let stop = chat.stop {
                Notice(symbol: "exclamationmark.circle.fill", tint: .orange, title: stop.title, detail: stop.detail) {
                    chat.stop = nil
                }
            }
            if let problem = chat.problem {
                Notice(symbol: "externaldrive.badge.exclamationmark", tint: .red, title: problem.title, detail: problem.detail) {
                    chat.problem = nil
                }
            }
            if chat.supervisor.phase != .running {
                Waiting(supervisor: chat.supervisor)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextBox(text: $chat.draft, label: "Message", maxHeight: 160, autofocus: true, submit: chat.submit)
                    .overlay(alignment: .topLeading) {
                        if chat.draft.isEmpty {
                            Text("Message")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 7)
                                .padding(.top, 6)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    .disabled(!chat.canCompose)
                Button("Reword", systemImage: "arrow.up") { chat.submit() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Reword")
                    .disabled(!chat.canSubmit)
                    // Level with a box of one line.
                    .padding(.bottom, 4)
            }
        }
        .padding(16)
    }
}

/// Why rewording waits, while Cloak is not running.
private struct Waiting: View {
    let supervisor: Supervisor

    var body: some View {
        let phase = supervisor.phase
        HStack(spacing: 8) {
            Image(systemName: phase.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text(phase))
            Spacer()
            switch phase {
            case .paused, .ready, .needsAttention:
                Button("Start") { supervisor.send(.start) }
            case .preparing, .stopping, .running:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func text(_ phase: Phase) -> String {
        switch phase {
        case .paused: "Cloak is paused. Start it to reword."
        case .ready: "Cloak isn't running. Start it to reword."
        case .preparing: "Cloak is starting."
        case .stopping: "Cloak is stopping."
        case .needsAttention(let reason): "\(reason.title) Start it again to reword."
        case .running: "Cloak is running."
        }
    }
}

private struct Notice: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.3)))
    }
}

extension Chat.Stop {
    var title: String {
        switch reason {
        case .tooLong: "This message is too long."
        case .timedOut: "Rewording took too long."
        case .refused: "The rewording didn't come back right."
        case .cancelled: "Rewording cancelled."
        case .stopped: "The model stopped."
        }
    }

    var detail: String {
        let next = switch reason {
        case .tooLong(let characters):
            "It has \(characters.formatted()) characters; the most is \(Rewrite.maxCharacters.formatted()). Shorten it, then try again."
        case .timedOut: "Try again, or shorten it."
        case .refused: "Try again."
        case .cancelled: ""
        case .stopped: "Start Cloak, then try again."
        }
        let back = newMessage ? "Your message is back in the box." : "The reworded text is as it was."
        return next.isEmpty ? back : back + " " + next
    }
}

extension Chat.Problem {
    var title: String {
        switch self {
        case .save: "Couldn't save this chat."
        case .delete: "Couldn't delete this chat."
        }
    }

    var detail: String {
        switch self {
        case .save: "Your latest change isn't on disk."
        case .delete: "It's still on this Mac."
        }
    }
}
