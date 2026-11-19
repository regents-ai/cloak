import AppKit
import CloakChat
import CloakControl
import CloakSupervisor
import SwiftUI

/// The Chat window: conversations on the left, newest first; the one shown
/// on the right, each message as written and as reworded, side by side (or
/// as written alone when it goes so), and its answer once sent, with the box
/// to write the next one at the bottom. In the agent's conversations, each
/// task in place of a message, with the steps the agent took.
/// Development mode's mark is always at the top.
struct ChatView: View {
    @Bindable var chat: Chat
    let showDetails: () -> Void

    static func window(_ chat: Chat, showDetails: @escaping () -> Void) -> NSWindow {
        let window = ClosingWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Chat"
        // Escape cancels a rewording here.
        window.closesOnEscape = false
        let content = NSHostingController(rootView: ChatView(chat: chat, showDetails: showDetails))
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
            Detail(chat: chat, showDetails: showDetails)
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
                let agent = chat.isAgent(conversation)
                let unsaved = chat.unsaved.contains(conversation.id)
                HStack(spacing: 6) {
                    Text(agent && conversation.turns.isEmpty ? "New task" : conversation.title)
                        .lineLimit(1)
                    if agent || unsaved {
                        Spacer(minLength: 0)
                    }
                    if unsaved {
                        Image(systemName: "externaldrive.badge.xmark")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Not saved")
                            .help("Not saved. What's new here is gone when Cloak quits.")
                    }
                    if agent {
                        Image(systemName: "hammer")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Agent")
                    }
                }
                .accessibilityElement(children: .combine)
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
    let showDetails: () -> Void
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
                    Compose(chat: chat, showDetails: showDetails)
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

/// The conversation's messages, in the order they were sent, each not yet
/// sent where it was added. One unsent message is open at a time, to be
/// edited, reworded again and sent; pressing another opens it instead.
private struct Turns: View {
    let chat: Chat
    let conversation: Conversation

    var body: some View {
        let rewording = chat.rewording?.conversation == conversation.id ? chat.rewording : nil
        let agent = chat.isAgent(conversation)
        let run = chat.agent.runs[conversation.id]
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if conversation.turns.isEmpty, rewording == nil {
                        VStack(alignment: .leading, spacing: 4) {
                            if agent {
                                Text("New task")
                                    .font(.title3.weight(.semibold))
                                Text("Each task is reworded on this Mac before the model sees it. You see both, each step the agent takes, and its answer.")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("New chat")
                                    .font(.title3.weight(.semibold))
                                Text(
                                    chat.settings.neverReword
                                        ? "Rewording is off, so each message is sent as you wrote it."
                                        : chat.settings.review
                                            ? "Each message is reworded on this Mac first. You see both, can edit the reworded one, and send it."
                                            : "Each message is reworded on this Mac, then sent as soon as it's ready. You see both."
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 8)
                    }
                    ForEach(conversation.turns) { turn in
                        if agent {
                            let running = run?.turn.id == turn.id ? run : nil
                            TaskCard(
                                chat: chat, conversation: conversation.id, turn: running?.turn ?? turn, run: running,
                                newest: turn.id == conversation.turns.last?.id)
                        } else {
                            TurnCard(
                                chat: chat, conversation: conversation.id, turn: turn,
                                open: chat.isOpen(turn, in: conversation),
                                rewording: rewording.flatMap { $0.turn == turn.id ? $0 : nil })
                        }
                    }
                    if let rewording, rewording.turn == nil {
                        PendingCard(chat: chat, rewording: rewording)
                    }
                }
                .padding(16)
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
/// marked in one, the words put in marked in the other, then its answer; a
/// message going as written shows its Original alone. The open one has the
/// lights and Send: nothing is sent unless Cloak routes it through Tor and,
/// unless its owner chose to send it as written, it is reworded. Unlinked
/// is never good in Development mode. While it has a reworded text, Send
/// Original Text beside Send sends it as written instead, with Never
/// reword's checkbox under them. Another unsent one is shrunk, says so, and
/// opens when pressed anywhere.
private struct TurnCard: View {
    let chat: Chat
    let conversation: UUID
    let turn: Turn
    let open: Bool
    let rewording: Chat.Rewording?
    @State private var hovering = false

    var body: some View {
        let sending = chat.sending[turn.id]
        let shrunk = !open && turn.answer == nil
        // The accent edge says a press opens it.
        Card(highlighted: hovering && shrunk && chat.rewording == nil) {
            if let reworded = turn.reworded {
                let diff = WordDiff(original: turn.original, reworded: reworded)
                HStack(alignment: .top, spacing: 12) {
                    Pane(title: "Original", count: diff.removed.count, mark: .removed) {
                        TextBox(text: .constant(turn.original), label: "Original", editable: false, marks: diff.removed, mark: .removed)
                    }
                    Pane(title: "Reworded", count: diff.added.count, mark: .added) {
                        TextBox(
                            text: open
                                ? Binding(get: { reworded }, set: { chat.edit(turn.id, in: conversation, to: $0) })
                                : .constant(reworded),
                            label: "Reworded", editable: open && sending == nil && chat.rewording == nil, marks: diff.added,
                            mark: .added)
                    }
                }
            } else {
                Pane(title: "Original", count: nil, mark: .removed) {
                    TextBox(text: .constant(turn.original), label: "Original", editable: false)
                }
            }
            if let answer = turn.answer {
                Pane(title: "Answer", count: nil, mark: .added) {
                    AnswerText(text: answer)
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
                Lights(reworded: turn.reworded.map { !Chat.isBlank($0) } ?? false, routed: chat.supervisor.phase == .running)
                HStack(spacing: 12) {
                    Button("Reword", systemImage: "arrow.clockwise") { chat.reword(turn, in: conversation) }
                        .disabled(!chat.canReword || sending != nil)
                    if let sending {
                        SendingProgress(started: sending.started)
                    }
                    Spacer()
                    let block = chat.sendBlock(turn)
                    let originalBlock = turn.reworded == nil ? nil : chat.originalBlock
                    if let words = originalBlock ?? block {
                        Text(words)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    // Each press of either sends, one under way or not.
                    if turn.reworded != nil {
                        Button("Send Original Text") { chat.sendOriginal(turn.id, in: conversation) }
                            .disabled(originalBlock != nil)
                    }
                    Button("Send") { chat.send(turn.id, in: conversation) }
                        .buttonStyle(.borderedProminent)
                        .disabled(block != nil)
                }
                if turn.reworded != nil {
                    HStack {
                        Spacer()
                        NeverReword(settings: chat.settings)
                            .toggleStyle(.checkbox)
                    }
                    .font(.callout)
                }
            } else if let sending {
                SendingProgress(started: sending.started)
            } else if turn.answer == nil {
                Text("Not sent")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            // Over the whole card, text boxes included, so a press anywhere
            // opens it. Off while a rewording is under way, which keeps its
            // own card open.
            if shrunk {
                Button { chat.opened = turn.id } label: {
                    Color.clear
                        .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open")
                .help("Open")
                .disabled(chat.rewording != nil)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// One task: as written and, once the door has reworded it, as reworded,
/// side by side, the words marked as in a message; the steps the agent took;
/// its answer. While it runs, its newest steps, how long it has run, and
/// Stop. One that ended without an answer says why and, as the newest, can
/// run again. The newest without an answer has the lights.
private struct TaskCard: View {
    let chat: Chat
    let conversation: UUID
    let turn: Turn
    let run: Agent.Run?
    let newest: Bool
    @State private var showingSteps = false

    var body: some View {
        let steps = turn.steps ?? []
        Card {
            HStack(alignment: .top, spacing: 12) {
                if let reworded = turn.reworded {
                    let diff = WordDiff(original: turn.original, reworded: reworded)
                    Pane(title: "Original", count: diff.removed.count, mark: .removed) {
                        TextBox(text: .constant(turn.original), label: "Original", editable: false, marks: diff.removed, mark: .removed)
                    }
                    Pane(title: "Reworded", count: diff.added.count, mark: .added) {
                        TextBox(text: .constant(reworded), label: "Reworded", editable: false, marks: diff.added, mark: .added)
                    }
                } else {
                    Pane(title: "Original", count: nil, mark: .removed) {
                        TextBox(text: .constant(turn.original), label: "Original", editable: false)
                    }
                    if run != nil {
                        Pane(title: "Reworded", count: nil, mark: .added) {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Rewording")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            if !steps.isEmpty {
                if run != nil {
                    // The newest few, the newest last.
                    Pane(title: "Steps", count: nil, mark: .added) {
                        StepList(steps: steps.suffix(5))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            showingSteps.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(showingSteps ? 90 : 0))
                                    .accessibilityHidden(true)
                                Text("^[\(steps.count) step](inflect: true)")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(showingSteps ? "Expanded" : "Collapsed")
                        if showingSteps {
                            StepList(steps: steps[...])
                                .paneBox()
                        }
                    }
                }
            }
            if let answer = turn.answer, !Chat.isBlank(answer) {
                Pane(title: "Answer", count: nil, mark: .added) {
                    AnswerText(text: answer)
                }
            }
            if run == nil, turn.answer == nil {
                if let end = chat.agent.ends[turn.id] {
                    EndRow(end: end)
                } else {
                    Text("Not finished")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if newest, turn.answer == nil {
                // The door sends nothing of a task that it has not reworded.
                Lights(reworded: true, routed: chat.supervisor.phase == .running)
            }
            if let run {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Working")
                    Text(timerInterval: run.started...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { chat.agent.stop(conversation) }
                }
                .accessibilityElement(children: .contain)
            } else if newest, turn.answer == nil {
                HStack(spacing: 12) {
                    Spacer()
                    let block = chat.runBlock
                    if let block {
                        Text(block)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("Run Again", systemImage: "arrow.clockwise") { chat.runAgain(turn, in: conversation) }
                        .buttonStyle(.borderedProminent)
                        .disabled(block != nil)
                }
            }
        }
    }
}

/// A task's steps, one a line: the tool, then the command or the file.
private struct StepList: View {
    let steps: ArraySlice<Step>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(steps.indices, id: \.self) { index in
                let step = steps[index]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(step.label)
                        .fontWeight(.medium)
                    if let detail = step.detail {
                        Text(detail)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Steps")
    }
}

/// Why a task ended without an answer.
private struct EndRow: View {
    let end: Agent.End

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(end.title)
                    .fontWeight(.medium)
                if let words = end.words {
                    Text(words)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
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

struct Card<Content: View>: View {
    /// An accent edge in place of the separator's.
    var highlighted = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator)))
    }
}

/// A titled text, with how many words are marked and how they look.
struct Pane<Content: View>: View {
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
                .paneBox()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// The box a pane's text sits in.
    fileprivate func paneBox() -> some View {
        padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
    }
}

/// The box for the next message, with a line under it while Never reword is
/// ticked, what stopped the last rewording, and, unless Cloak is running,
/// why rewording or sending waits and a Start button. Its button rewords,
/// or sends when nothing is left to review: with Never reword ticked or
/// Review off. In the agent's conversation, the box for the next task,
/// with Run, or Stop while a task runs there, and a note when the agent
/// starts without the earlier tasks. While the conversation is empty, what
/// it is to be: a chat or the agent's. Above either box, its details; at
/// the foot, the Cover, Tor and zkAPI switches.
private struct Compose: View {
    @Bindable var chat: Chat
    let showDetails: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let conversation = chat.selected
        let agent = conversation.map(chat.isAgent) ?? false
        let running = conversation.flatMap { chat.agent.runs[$0.id] } != nil
        let neverReword = !agent && chat.settings.neverReword
        let sends = neverReword || (!agent && !chat.settings.review)
        let label = agent ? "Task" : "Message"
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
                Waiting(supervisor: chat.supervisor, to: agent ? "run" : sends ? "send" : "reword", showDetails: showDetails)
            }
            DetailsRow(chat: chat)
            HStack(alignment: .bottom, spacing: 10) {
                TextBox(text: $chat.draft, label: label, maxHeight: 160, autofocus: true, submit: chat.submit)
                    .overlay(alignment: .topLeading) {
                        if chat.draft.isEmpty {
                            Text(label)
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
                if running, let conversation {
                    Button("Stop", systemImage: "stop.fill") { chat.agent.stop(conversation.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .help("Stop")
                        .keyboardShortcut(".", modifiers: .command)
                        .padding(.bottom, 4)
                } else {
                    let title: LocalizedStringKey = agent ? "Run" : sends ? "Send" : "Reword"
                    Button(title, systemImage: "arrow.up") { chat.submit() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .help(title)
                        .disabled(!chat.canSubmit)
                        // Level with a box of one line.
                        .padding(.bottom, 4)
                }
            }
            HStack(spacing: 16) {
                if let conversation, conversation.turns.isEmpty, chat.rewording?.conversation != conversation.id {
                    Picker("Type", selection: $chat.kind) {
                        Text("Chat").tag(Chat.Kind.chat)
                        Text("Agent").tag(Chat.Kind.agent)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if neverReword {
                    // Constant while ticked, since no reworded text is shown.
                    Label {
                        Text("Rewording is off. Messages go as you wrote them.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } else if agent, let conversation, chat.supervisor.phase == .running, chat.startsFresh(conversation) {
                    Label("The agent won't remember the earlier tasks here.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // While Cloak is not running, the notice above says so.
                if agent, chat.supervisor.phase == .running, let block = chat.runBlock {
                    Text(block)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            Switches(settings: chat.settings, supervisor: chat.supervisor)
        }
        .padding(16)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: chat.picks.details)
    }
}

/// Cover, Tor and zkAPI, each a small glass pill whose dot shows at a glance
/// whether it is on. Cover is the setting (`AppSettings.cover`), which the
/// guest takes at Start, so while Cloak runs with the other value a few
/// words beside the pills say when it changes. Tor is always on, and zkAPI
/// is off, since one wallet pays for everything (the Development bar);
/// neither changes here yet.
private struct Switches: View {
    @Bindable var settings: AppSettings
    let supervisor: Supervisor

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                SwitchPill(title: "Cover", isOn: $settings.cover, help: "Background visits to ordinary public pages.")
                SwitchPill(title: "Tor", isOn: .constant(true), help: "Always on for now.", fixed: true)
                SwitchPill(title: "zkAPI", isOn: .constant(false), help: "Not available yet.", fixed: true)
            }
            if let started = supervisor.cover, started != settings.cover {
                Text("Cover changes at the next Start.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// One switch, as a small glass pill: a dot, filled while on and hollow
/// while off, then its name; read by VoiceOver as a switch with its state.
/// One `fixed` is shown but can't be changed here yet: not a button, its
/// name dimmed, and its help says why.
private struct SwitchPill: View {
    let title: String
    @Binding var isOn: Bool
    let help: String
    var fixed = false

    var body: some View {
        let pill = HStack(spacing: 5) {
            Image(systemName: isOn ? "circle.fill" : "circle")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(isOn ? Color.green : Color.secondary)
            Text(title)
                .foregroundStyle(fixed ? HierarchicalShapeStyle.secondary : .primary)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 24)
        .contentShape(.capsule)
        Group {
            if fixed {
                pill
                    .glassEffect(.regular, in: .capsule)
            } else {
                Button { isOn.toggle() } label: { pill }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .disabled(fixed)
        }
        .help(help)
    }
}

/// Why rewording, sending as written or the agent waits while Cloak is not
/// running. Without the model, the way to its download in Details takes the
/// place of Start.
private struct Waiting: View {
    let supervisor: Supervisor
    /// What waits, as the verb ending each sentence: reword, send or run.
    let to: String
    let showDetails: () -> Void

    var body: some View {
        let phase = supervisor.phase
        HStack(spacing: 8) {
            Image(systemName: phase.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text(phase))
            Spacer()
            switch phase {
            case .needsAttention(.modelMissing):
                Button("Download Model…", action: showDetails)
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
        case .paused: "Cloak is paused. Start it to \(to)."
        case .ready: "Cloak isn't running. Start it to \(to)."
        case .preparing: "Cloak is starting."
        case .stopping: "Cloak is stopping."
        case .needsAttention(.modelMissing): "The model isn't installed. Download it to \(to)."
        case .needsAttention(let reason): "\(reason.title) Start it again to \(to)."
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
        let back = newMessage ? "Your message is back in the box." : "The message is as it was."
        return next.isEmpty ? back : back + " " + next
    }
}

extension Step {
    /// What the agent did, in a word: its four own tools by what they do,
    /// any other by its name.
    var label: String {
        switch tool {
        case "bash": "Ran"
        case "read": "Read"
        case "edit": "Edited"
        case "write": "Wrote"
        default: tool.prefix(1).uppercased() + tool.dropFirst()
        }
    }
}

extension Agent.End {
    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .cloakStopped: "Cloak stopped"
        case .unreachable: "No connection"
        case .failed: "Not finished"
        }
    }

    var words: String? {
        switch self {
        case .stopped: nil
        case .cloakStopped: "Cloak was paused or stopped, so the task ended."
        case .unreachable: "The agent couldn't reach Cloak. Agents says why."
        case .failed(let sentence): sentence ?? "The agent stopped before it finished."
        }
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
