import AppKit
import CloakChat
import CloakControl
import CloakSupervisor
import SwiftUI

/// The Chat window: conversations on the left, newest first; the one shown
/// on the right, each message as written and as reworded, side by side (or
/// as written alone when it goes so), and its answer once sent, with the box
/// to write the next one at the bottom. In the agent's conversations, each
/// task in place of a message, with the steps the agent took. In NEAR
/// Private AI's conversations, each message as written and its answer; in
/// Local Llama's, each message as written and the answer of the model on
/// this Mac. The mode's mark is at the top. The Modes page shows on it as a
/// sheet.
struct ChatView: View {
    @Bindable var chat: Chat
    let showDetails: () -> Void
    let showNearSettings: () -> Void
    let showLlamaSettings: () -> Void

    static func window(
        _ chat: Chat, showDetails: @escaping () -> Void, showNearSettings: @escaping () -> Void,
        showLlamaSettings: @escaping () -> Void
    ) -> NSWindow {
        let window = ClosingWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Chat"
        // Escape cancels a rewording here.
        window.closesOnEscape = false
        let content = NSHostingController(
            rootView: ChatView(
                chat: chat, showDetails: showDetails, showNearSettings: showNearSettings, showLlamaSettings: showLlamaSettings))
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
            Detail(chat: chat, showDetails: showDetails, showNearSettings: showNearSettings, showLlamaSettings: showLlamaSettings)
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
                let mode = chat.kind(of: conversation)
                let unsaved = chat.unsaved.contains(conversation.id)
                HStack(spacing: 6) {
                    Text(agent && conversation.turns.isEmpty ? "New task" : conversation.title)
                        .lineLimit(1)
                    if agent || mode != .v || unsaved {
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
                        Image(systemName: Chat.Kind.agentSymbol)
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Chat.Kind.agentName)
                            .help("\(Chat.Kind.agentName) chat")
                    }
                    // V's chats have no mark.
                    if mode != .v {
                        Image(systemName: mode.symbol)
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(mode.name)
                            .help("\(mode.name) chat")
                    }
                }
                .accessibilityElement(children: .combine)
                .sidebarHover(selected: chat.selection == conversation.id)
                .tag(conversation.id)
                .contextMenu {
                    Button("Delete", role: .destructive) { deleting = conversation }
                }
            }
            // Choosing one shows why it can't open.
            ForEach(chat.unreadable, id: \.self) { id in
                Label("Can't open", systemImage: "lock")
                    .foregroundStyle(.secondary)
                    .sidebarHover(selected: chat.selection == id)
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
    let showNearSettings: () -> Void
    let showLlamaSettings: () -> Void

    /// The conversation in front's mode; V's while none is, as the mark at
    /// the top shows.
    private var kind: Chat.Kind {
        chat.selected.map(chat.kind(of:)) ?? .v
    }

    var body: some View {
        VStack(spacing: 0) {
            switch kind {
            case .v: VBar()
            case .token: TokenBar()
            case .near: NearBar(settings: chat.settings)
            case .llama: LlamaBar()
            }
            Divider()
            content
        }
        .toolbar {
            ToolbarItem {
                CoverToggle(settings: chat.settings, supervisor: chat.supervisor)
            }
            ToolbarItem {
                WalletButton(chat: chat, v: kind == .v)
            }
        }
        .sheet(isPresented: $chat.showingWallet) {
            WalletView(
                wallet: chat.wallet, payer: chat.payer, settings: chat.settings, nearMode: chat.nearMode, kind: kind,
                tokens: chat.selected?.tokens, showNearSettings: showNearSettings)
        }
        .sheet(isPresented: $chat.showingModes) {
            ModesPage(chat: chat)
        }
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
                    Compose(chat: chat, showDetails: showDetails, showLlamaSettings: showLlamaSettings)
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

/// Cover, the setting itself (`AppSettings.cover`), as a toggle in Chat's
/// toolbar in every mode: its symbol, filled while on, read by VoiceOver as
/// a switch with its state. The guest takes it at Start, so while Cloak
/// runs with the other value a clock sits on the symbol's corner, and the
/// help and the hint end with when it changes.
private struct CoverToggle: View {
    @Bindable var settings: AppSettings
    let supervisor: Supervisor

    var body: some View {
        let waits = supervisor.cover.map { $0 != settings.cover } == true
        let later = "Cover changes after Pause, then Start."
        let help = "Cover traffic: while Cloak is running, it visits ordinary public pages in the background through Tor, so your real requests through Tor stand out less."
        Toggle(isOn: $settings.cover) {
            Label {
                Text("Cover")
            } icon: {
                Image(systemName: settings.cover ? "cloud.fog.fill" : "cloud.fog")
                    .contentTransition(.symbolEffect(.replace))
                    .overlay(alignment: .bottomTrailing) {
                        if waits {
                            Image(systemName: "clock")
                                .font(.system(size: 8, weight: .bold))
                                .padding(1)
                                .background(.background, in: .circle)
                                .offset(x: 3, y: 3)
                        }
                    }
            }
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .accessibilityRepresentation {
            Toggle("Cover", isOn: $settings.cover)
                .toggleStyle(.switch)
                .accessibilityHint(waits ? later : "")
        }
        .help(waits ? "\(help) \(later)" : help)
    }
}

/// Wallet, in Chat's toolbar: the sheet for the conversation in front. In a
/// V chat, while V's deposit expires within the warning or has expired, a
/// warning sits on the symbol's corner, orange then red, and the help says
/// when.
private struct WalletButton: View {
    let chat: Chat
    let v: Bool

    var body: some View {
        let band = v ? chat.payer.band(at: .now) : nil
        let warning: (Color, String)? =
            switch band {
            case .near?: (.orange, "Expires \(chat.payer.expiry?.formatted(.dateTime.day().month()) ?? ""). Withdraw before then.")
            case .due?: (.red, "Can be taken now.")
            case .far?, nil: nil
            }
        Button {
            chat.showingWallet = true
        } label: {
            Label {
                Text("Wallet")
            } icon: {
                Image(systemName: "creditcard")
                    .overlay(alignment: .bottomTrailing) {
                        if let (tint, _) = warning {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(tint)
                                .background(.background, in: .circle)
                                .offset(x: 3, y: 3)
                        }
                    }
            }
        }
        .help(warning.map { "Wallet. \($0.1)" } ?? "Wallet")
        .accessibilityValue(warning?.1 ?? "")
        .disabled(!chat.isOpen)
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
        let mode = chat.kind(of: conversation)
        let run = chat.agent.runs[conversation.id]
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // What each mode does is on the Modes page.
                    if conversation.turns.isEmpty, rewording == nil {
                        Text(agent ? "New task" : "New chat")
                            .font(.title3.weight(.semibold))
                            .padding(.top, 8)
                    }
                    ForEach(conversation.turns) { turn in
                        if agent {
                            let running = run?.turn.id == turn.id ? run : nil
                            TaskCard(
                                chat: chat, conversation: conversation.id, mode: mode, turn: running?.turn ?? turn, run: running,
                                newest: turn.id == conversation.turns.last?.id)
                        } else if mode == .llama {
                            LlamaCard(
                                chat: chat, conversation: conversation.id, turn: turn,
                                answering: chat.answering[conversation.id].flatMap { $0.turn == turn.id ? $0 : nil },
                                newest: turn.id == conversation.turns.last?.id)
                        } else {
                            TurnCard(
                                chat: chat, conversation: conversation.id, turn: turn, mode: mode,
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
/// lights, Reword, which only rewords, and Send: nothing is sent unless
/// Cloak routes it through Tor and, unless its owner chose to send it as
/// written, it is reworded. In Token Inference a third light says the
/// provider can link the chats. While it has a reworded text, the drop-down
/// beside Send holds Send Original Text, which sends it as written instead,
/// and Never reword. Another unsent one is shrunk, marked so, and opens when
/// pressed anywhere. A NEAR message is shown as written alone, and the open
/// one has Send, with no lights and no rewording; its answer, when NEAR
/// counted its tokens, has a mark that says how many, and under it each
/// trace shared from it (`TraceStatusRows`).
private struct TurnCard: View {
    let chat: Chat
    let conversation: UUID
    let turn: Turn
    let mode: Chat.Kind
    let open: Bool
    let rewording: Chat.Rewording?
    @State private var hovering = false

    var body: some View {
        let near = mode == .near
        let sending = chat.sending[turn.id]
        let shrunk = !open && turn.answer == nil
        let notSent = rewording == nil && shrunk && sending == nil
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
                let title = near ? "Message" : "Original"
                Pane(title: title, count: nil, mark: .removed) {
                    TextBox(text: .constant(turn.original), label: title, editable: false)
                }
            }
            if let answer = turn.answer {
                Pane(title: "Answer", count: nil, mark: .added) {
                    AnswerText(text: answer)
                } accessory: {
                    if let tokens = turn.tokens {
                        TokenMark(tokens: tokens)
                    }
                }
            }
            if !near, let stop = chat.sendStop, stop.turn == turn.id {
                Group {
                    switch stop.stop {
                    case .tempo(let stop):
                        StopRow(stop: stop) { chat.sendStop = nil }
                    case .zkapi(let stop):
                        PayStopRow(stop: stop, showWallet: { chat.showingWallet = true }) { chat.sendStop = nil }
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            if near, let stop = chat.nearMode.sendStop, stop.turn == turn.id {
                NearStopRow(stop: stop.stop) { chat.nearMode.sendStop = nil }
                    .padding(12)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            if near {
                TraceStatusRows(share: chat.nearMode.share, route: chat.nearMode.route, chat: conversation, turn: turn.id)
            }
            if let rewording {
                Progress(chat: chat, started: rewording.started)
            } else if open {
                if !near {
                    Lights(
                        reworded: turn.reworded.map { !Chat.isBlank($0) } ?? false, routed: chat.supervisor.phase == .running,
                        linkable: mode == .token)
                }
                HStack(spacing: 12) {
                    if !near {
                        SymbolButton("Reword", symbol: "pencil.line") { chat.reword(turn, in: conversation) }
                            .disabled(!chat.canReword || sending != nil)
                    }
                    if let sending {
                        Busy(title: "Sending", started: sending.started)
                    }
                    Spacer()
                    let block = near ? chat.nearMode.sendBlock : chat.sendBlock(turn, in: mode)
                    let originalBlock = turn.reworded == nil ? nil : chat.originalBlock(in: mode)
                    if let words = originalBlock ?? block {
                        Text(words)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    // Each press of Send or Send Original Text sends, one
                    // under way or not.
                    HStack(spacing: 0) {
                        Button("Send", systemImage: "arrow.up") { chat.send(turn.id, in: conversation) }
                            .buttonStyle(RoundButtonStyle(diameter: 20))
                            .help("Send")
                            .disabled(block != nil)
                        if turn.reworded != nil {
                            SendOptions(settings: chat.settings, blocked: originalBlock != nil) {
                                chat.sendOriginal(turn.id, in: conversation)
                            }
                        }
                    }
                }
            } else if let sending {
                Busy(title: "Sending", started: sending.started)
            } else if turn.answer == nil {
                // Only its room: the mark is drawn over the press that opens
                // the card, so its help shows.
                NotSent()
                    .hidden()
            }
        }
        .overlay(alignment: .bottomLeading) {
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
            if notSent {
                NotSent()
                    .padding(16)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// A shrunk card's mark while it isn't sent: a small hollow circle, dashed,
/// as the switches' hollow dot means off.
private struct NotSent: View {
    var body: some View {
        Image(systemName: "circle.dashed")
            .font(.callout)
            .foregroundStyle(.secondary)
            .help("Not sent")
            .accessibilityLabel("Not sent")
    }
}

/// The drop-down beside a card's Send while it has a reworded text: Send
/// Original Text, off as Send is but for a blank reworded text, which it
/// does not send; and Never reword, the setting itself, which turns Review
/// off as it does in Settings (`AppSettings.neverReword`).
private struct SendOptions: View {
    let settings: AppSettings
    let blocked: Bool
    let sendOriginal: () -> Void

    var body: some View {
        Menu {
            Button("Send Original Text", action: sendOriginal)
                .disabled(blocked)
            NeverReword(settings: settings)
        } label: {
            Label("Send Options", systemImage: "chevron.down")
                .labelStyle(.iconOnly)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        // Plain, so the whole 28 points answer the pointer, not only the
        // chevron.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hover(Circle())
        .help("Send Options")
    }
}

/// One task: as written and, once the door has reworded it, as reworded,
/// side by side, the words marked as in a message; the steps the agent took;
/// its answer. While it runs, its newest steps, how long it has run, and
/// Stop. One that ended without an answer says why and, as the newest, can
/// run again; in V, one stopped for want of a deposit says so, with
/// Wallet. The newest without an answer has the lights.
private struct TaskCard: View {
    let chat: Chat
    let conversation: UUID
    let mode: Chat.Kind
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
                        .hover(RoundedRectangle(cornerRadius: 6), outset: 4)
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
                    EndRow(title: end.title, words: end.words)
                    if mode == .v, case .failed = end, chat.payer.state == .none {
                        HStack(spacing: 12) {
                            Text("Deposit to run.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Wallet…") { chat.showingWallet = true }
                        }
                    }
                } else {
                    Text("Not finished")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if newest, turn.answer == nil {
                // The door sends nothing of a task that it has not reworded.
                Lights(reworded: true, routed: chat.supervisor.phase == .running, linkable: mode == .token)
            }
            if let run {
                HStack(spacing: 8) {
                    Busy(title: "Working", started: run.started)
                    Spacer()
                    Button("Stop") { chat.agent.stop(conversation) }
                }
                .accessibilityElement(children: .contain)
            } else if newest, turn.answer == nil {
                HStack(spacing: 12) {
                    Spacer()
                    let block = chat.runBlock(in: mode)
                    if let block {
                        Text(block)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    SymbolButton("Run Again", symbol: "arrow.clockwise") { chat.runAgain(turn, in: conversation) }
                        .disabled(block != nil)
                }
            }
        }
    }
}

/// One Local Llama message: as written, then the answer of the model on
/// this Mac. While the model answers, how long it has worked, and Stop. One
/// without an answer says why and, as the newest, can be asked again,
/// unless the chat has grown too long for the model.
private struct LlamaCard: View {
    let chat: Chat
    let conversation: UUID
    let turn: Turn
    let answering: Chat.Answering?
    let newest: Bool

    var body: some View {
        Card {
            Pane(title: "Message", count: nil, mark: .removed) {
                TextBox(text: .constant(turn.original), label: "Message", editable: false)
            }
            if let answer = turn.answer {
                Pane(title: "Answer", count: nil, mark: .added) {
                    AnswerText(text: answer)
                }
            } else if let answering {
                HStack(spacing: 8) {
                    Busy(title: "Working", started: answering.started)
                    Spacer()
                    Button("Stop") { chat.stopAnswer(in: conversation) }
                }
                .accessibilityElement(children: .contain)
            } else {
                let stop = chat.answerStops[turn.id]
                EndRow(title: stop?.title ?? "Not answered", words: stop?.words)
                if newest, stop != .tooLong {
                    HStack(spacing: 12) {
                        Spacer()
                        if let block = chat.llamaBlock {
                            Text(block.words)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        SymbolButton("Ask Again", symbol: "arrow.clockwise") { chat.ask(turn.id, in: conversation) }
                            .disabled(chat.llamaBlock != nil)
                    }
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

/// Why a task, or a Local Llama message, ended without an answer.
private struct EndRow: View {
    let title: String
    let words: String?

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
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Whether the message is reworded and routed through Tor: a symbol each,
/// green when it is, orange when not, with the state in words as its help
/// and for VoiceOver. Routed has Tor's symbol, as the Tor switch does. In
/// Token Inference a third, always orange, says one wallet pays for every
/// chat.
private struct Lights: View {
    let reworded: Bool
    let routed: Bool
    let linkable: Bool

    var body: some View {
        HStack(spacing: 4) {
            Light(symbol: "textformat", good: reworded, words: reworded ? "Reworded" : "Not reworded")
            Light(symbol: torSymbol, good: routed, words: routed ? "Routed through Tor" : "Not routed: Cloak isn't running")
            if linkable {
                Light(symbol: "link", good: false, words: "The provider can link your chats, because one wallet pays for all of them.")
            }
        }
    }
}

private struct Light: View {
    let symbol: String
    let good: Bool
    let words: String

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(good ? .green : .orange)
            .frame(width: 24, height: 24)
            .contentShape(.rect)
            .help(words)
            .accessibilityLabel(words)
    }
}

/// A spinner and how long it has been since `started`, what is under way
/// named in its help and for VoiceOver: Sending or Working.
private struct Busy: View {
    let title: String
    let started: Date

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(title)
            Text(timerInterval: started...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .help(title)
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
    /// An accent edge over the separator's, fading in and out as a hover
    /// does (`Hover.swift`).
    var highlighted = false
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor)
                .opacity(highlighted ? 1 : 0)
                .animation(reduceMotion ? nil : .hover, value: highlighted)
        }
    }
}

/// A titled text, with how many words are marked and how they look, and
/// at the end of its title's line any mark of its own.
struct Pane<Content: View, Accessory: View>: View {
    let title: String
    let count: Int?
    let mark: TextBox.Mark
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory

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
                accessory
            }
            content
                .paneBox()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Pane where Accessory == EmptyView {
    init(title: String, count: Int?, mark: TextBox.Mark, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, mark: mark, content: content, accessory: { EmptyView() })
    }
}

/// What NEAR counted for an answer: a small mark at the end of its title's
/// line, the counts in its help and for VoiceOver, as "1,204 tokens in, 356
/// out", the numbers as this Mac writes them.
private struct TokenMark: View {
    let tokens: Tokens

    var body: some View {
        let words = String(AttributedString(localized: "^[\(tokens.input) token](inflect: true) in, \(tokens.output) out").characters)
        Image(systemName: "number.circle")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .help(words)
            .accessibilityLabel("Tokens")
            .accessibilityValue(words)
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

/// The box for the next message, with a warning under it while Never
/// reword is ticked, what stopped the last rewording, and, unless Cloak is
/// running, the state and a Start button. Its button rewords, its symbol
/// Reword's, or sends when nothing is left to review: with Never reword
/// ticked or Review off. In the agent's conversation, the box for the next
/// task, with Run, or Stop while a task runs there, and a note when the
/// agent starts without the earlier tasks. While the conversation is empty,
/// what it is to be: V, Token Inference, NEAR Private AI or Local Llama,
/// and in V and Token Inference the Agent switch, which makes it the
/// agent's; beside them Modes, which shows the Modes page. Above either
/// box, its details; at the foot, the Tor and zkAPI switches. In a NEAR
/// Private AI conversation,
/// the box's button sends each message as written, with no details, and at
/// the foot NEAR's Tor switch and what its hardware check last found. In a
/// Local Llama conversation, it asks the model on this Mac, with Stop while
/// the model answers, no details and no switches, and Cloak need not be
/// running; when asking is certain to stop, why, and the way on.
private struct Compose: View {
    @Bindable var chat: Chat
    let showDetails: () -> Void
    let showLlamaSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let conversation = chat.selected
        let mode = conversation.map(chat.kind(of:)) ?? chat.kind
        let agent = conversation.map(chat.isAgent) ?? false
        let near = conversation.map(chat.isNear) ?? false
        let llama = conversation.map(chat.isLlama) ?? false
        let running = conversation.flatMap { chat.agent.runs[$0.id] } != nil
        let answering = conversation.flatMap { chat.answering[$0.id] } != nil
        let neverReword = !agent && !near && !llama && chat.settings.neverReword
        let sends = neverReword || near || (!agent && !chat.settings.review)
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
            // NEAR's status line and Send say what Cloak not running stops;
            // Local Llama needs only the model.
            if llama {
                if let block = chat.llamaBlock {
                    LlamaStop(block: block, showDetails: showDetails, showLlamaSettings: showLlamaSettings)
                }
            } else if !near, chat.supervisor.phase != .running {
                Waiting(supervisor: chat.supervisor, to: agent ? "run" : sends ? "send" : "reword", showDetails: showDetails)
            }
            if !near, !llama {
                DetailsRow(chat: chat)
            }
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
                if running || answering, let conversation {
                    Button("Stop", systemImage: "stop.fill") {
                        if llama { chat.stopAnswer(in: conversation.id) } else { chat.agent.stop(conversation.id) }
                    }
                        .buttonStyle(RoundButtonStyle())
                        .help("Stop")
                        .keyboardShortcut(".", modifiers: .command)
                        .padding(.bottom, 4)
                } else {
                    let title: LocalizedStringKey = agent ? "Run" : llama ? "Ask" : sends ? "Send" : "Reword"
                    // Reword's symbol where the press only rewords.
                    Button(title, systemImage: !agent && !llama && !sends ? "pencil.line" : "arrow.up") { chat.submit() }
                        .buttonStyle(RoundButtonStyle())
                        .help(title)
                        .disabled(!chat.canSubmit)
                        // Level with a box of one line.
                        .padding(.bottom, 4)
                }
            }
            HStack(spacing: 16) {
                if let conversation, conversation.turns.isEmpty, chat.rewording?.conversation != conversation.id {
                    HStack(spacing: 6) {
                        ModeSwitch(kind: $chat.kind)
                            .fixedSize()
                        if chat.kind.hasAgent {
                            SwitchPill(
                                title: Chat.Kind.agentName, symbol: Chat.Kind.agentSymbol, isOn: $chat.agentOn,
                                help: Chat.Kind.agentAbout)
                        }
                        SymbolButton("Modes", symbol: "info.circle") { chat.showingModes = true }
                            .foregroundStyle(.secondary)
                    }
                }
                if neverReword {
                    // Constant while ticked, since no reworded text is shown.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Rewording is off. Messages go as you wrote them.")
                        .accessibilityLabel("Rewording is off. Messages go as you wrote them.")
                } else if agent, let conversation, chat.supervisor.phase == .running, chat.startsFresh(conversation) {
                    Label("The agent won't remember the earlier tasks here.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // While Cloak is not running, the notice above says so.
                if agent, chat.supervisor.phase == .running, let block = chat.runBlock(in: mode) {
                    Text(block)
                        .foregroundStyle(.secondary)
                }
                if near, let block = chat.nearMode.sendBlock {
                    Text(block)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if near {
                NearSwitches(settings: chat.settings, nearMode: chat.nearMode, conversation: conversation)
            } else if !llama {
                Switches(mode: mode)
            }
        }
        .padding(16)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: chat.picks.details)
    }
}

/// Tor's symbol, for the Tor switches and the Routed light: three relays
/// joined, as Tor passes each message through three.
private let torSymbol = "point.3.connected.trianglepath.dotted"

/// Tor and zkAPI, each a small glass pill of its symbol whose dot shows at
/// a glance whether it is on. Tor is always on. zkAPI is on in V, which
/// pays each request with a new key, and off in Token Inference, which
/// pays from one wallet. Neither changes here, and a press on either says
/// so.
private struct Switches: View {
    let mode: Chat.Kind

    var body: some View {
        let v = mode == .v
        HStack(spacing: 6) {
            SwitchPill(
                title: "Tor", symbol: torSymbol, isOn: .constant(true),
                help: "Tor: your messages reach the AI service from a Tor address, not this Mac's.",
                fixed: v ? "Tor stays on in V chats." : "Tor stays on in Token Inference chats.")
            SwitchPill(
                title: "zkAPI", symbol: "ticket", isOn: .constant(v),
                help: v ? "Each request is paid with a new key." : "zkAPI is off: one wallet pays for every chat.",
                fixed: v ? "zkAPI stays on in V chats." : "Token Inference pays from one wallet. V pays with zkAPI.")
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// NEAR mode's switch, Tor (`AppSettings.nearTor`), and beside it what
/// NEAR's hardware check last found. The check runs as this shows, and
/// again each time the route changes. In a NEAR chat with a message, the
/// share control at the end (`ShareControl`).
private struct NearSwitches: View {
    @Bindable var settings: AppSettings
    let nearMode: NearMode
    let conversation: Conversation?

    var body: some View {
        HStack(spacing: 6) {
            SwitchPill(
                title: "Tor", symbol: torSymbol, isOn: $settings.nearTor,
                help: settings.nearTor ? "NEAR and Intel see a Tor address. Slower." : "NEAR and Intel see this Mac's internet address.")
            NearStatus(settings: settings, nearMode: nearMode)
                .padding(.leading, 4)
            Spacer(minLength: 0)
            if let conversation, conversation.isNear, !conversation.isAgent {
                ShareControl(share: nearMode.share, route: nearMode.route, conversation: conversation)
            }
        }
        .font(.callout)
        .task(id: nearMode.route) { await nearMode.check() }
    }
}

/// What NEAR's hardware check last found: under way, with how long it has
/// taken; passed, as a shield and how long ago, the shield grey once the
/// next message checks again; or stopped, saying why, with Check Again; or
/// that Tor needs Cloak running. What a symbol stands for is its help.
private struct NearStatus: View {
    let settings: AppSettings
    let nearMode: NearMode

    var body: some View {
        if nearMode.route == nil {
            Text("Not checked. Tor needs Cloak running.")
                .foregroundStyle(.secondary)
        } else if let started = nearMode.checking {
            Busy(title: settings.nearTor ? "Checking NEAR's hardware through Tor" : "Checking NEAR's hardware", started: started)
        } else if let stop = nearMode.checkStop {
            HStack(spacing: 4) {
                Text("Not checked: \(stop.title).")
                    .foregroundStyle(.secondary)
                SymbolButton("Check Again", symbol: "arrow.clockwise") { Task { await nearMode.check() } }
            }
        } else if let proof = nearMode.proof {
            // Each minute from the check, so the age and the freshness
            // passing show as they happen.
            TimelineView(.periodic(from: proof.passedAt, by: 60)) { context in
                let age = context.date.timeIntervalSince(proof.passedAt)
                let fresh = age < Double(settings.proofFreshness.rawValue)
                let words = Self.checked(proof, age: age) + (fresh ? "." : ". Next message checks again.")
                Label {
                    Text(Self.age(age))
                } icon: {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(fresh ? .green : .secondary)
                }
                .foregroundStyle(.secondary)
                .help(words)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words)
            }
        }
    }

    /// "Checked 2 min ago: 1 server, 8 GPUs", or with several servers,
    /// "Checked 2 min ago: 3 servers, 8 GPUs on one".
    private static func checked(_ proof: NearProof, age: TimeInterval) -> String {
        let minutes = Int(age / 60)
        let when = minutes < 1 ? "just now" : "\(minutes) min ago"
        let gpus = proof.gpus == 1 ? "1 GPU" : "\(proof.gpus) GPUs"
        return proof.modelServers == 1
            ? "Checked \(when): 1 server, \(gpus)"
            : "Checked \(when): \(proof.modelServers) servers, \(gpus) on one"
    }

    /// "now", or "9 min".
    private static func age(_ age: TimeInterval) -> String {
        let minutes = Int(age / 60)
        return minutes < 1 ? "now" : "\(minutes) min"
    }
}

/// NEAR Private AI's mark, with what goes and who pays as its help; and Limits, what NEAR's hardware check does
/// not cover, behind the info button at the end.
private struct NearBar: View {
    let settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            ModePill(title: "NEAR Private AI", help: "Sent as you wrote it. Your NEAR key pays.", tint: .accentColor)
            Spacer(minLength: 0)
            InfoButton("Limits") { Limits(settings: settings) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }
}

/// Local Llama's mark, with where the answer comes from and what it needs
/// as its help.
private struct LlamaBar: View {
    var body: some View {
        HStack(spacing: 10) {
            ModePill(
                title: "Local Llama", help: "Answered on this Mac, with nothing to pay and no need to start Cloak.",
                tint: .accentColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }
}

/// What NEAR's hardware check does not cover, as the settings are now.
private struct Limits: View {
    let settings: AppSettings

    var body: some View {
        let freshness = switch settings.proofFreshness {
        case .everyMessage: "Each message is checked first."
        case .tenMinutes: "With a reused check, the hardware was checked up to 10 minutes ago."
        case .oneHour: "With a reused check, the hardware was checked up to 1 hour ago."
        }
        let lines = [
            "The model's software isn't part of the measurement.",
            "Your key ties every message to one NEAR account.",
            "The GPU check covers one server, which NEAR picks.",
            freshness,
            settings.nearTor ? "Through Tor, they see a Tor address." : "Tor is off, so NEAR and Intel see this Mac's internet address.",
            "On 8 November a flaw on one NEAR server exposed requests in progress.",
        ]
        VStack(alignment: .leading, spacing: 8) {
            Text("Not checked")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}

/// The mode switch under an empty chat's box: a segment a mode, each its
/// symbol and the chosen one its name too. Agent stays as it is across a
/// change, and shows again in a mode that has it. A segment's help names
/// its mode and says what it does and who pays. VoiceOver reads it as a radio group, each segment by
/// its mode's name. AppKit's own segmented control, since SwiftUI's draws a
/// segment's symbol or its name, never both.
private struct ModeSwitch: NSViewRepresentable {
    @Binding var kind: Chat.Kind

    func makeCoordinator() -> Coordinator {
        Coordinator(kind: $kind)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentCount = Chat.Kind.modes.count
        for (index, mode) in Chat.Kind.modes.enumerated() {
            control.setImage(NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.name), forSegment: index)
            control.setToolTip(mode.about, forSegment: index)
        }
        control.target = context.coordinator
        control.action = #selector(Coordinator.choose(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.kind = $kind
        for (index, mode) in Chat.Kind.modes.enumerated() {
            control.setLabel(mode == kind ? mode.name : "", forSegment: index)
        }
        control.selectedSegment = Chat.Kind.modes.firstIndex(of: kind) ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor final class Coordinator: NSObject {
        var kind: Binding<Chat.Kind>

        init(kind: Binding<Chat.Kind>) {
            self.kind = kind
        }

        @objc func choose(_ control: NSSegmentedControl) {
            kind.wrappedValue = Chat.Kind.modes[control.selectedSegment]
        }
    }
}

extension Chat.Kind {
    /// The modes, in the switch's and the Modes page's order.
    static let modes: [Chat.Kind] = [.v, .token, .near, .llama]

    static let agentName = "Agent"
    static let agentSymbol = "hammer"
    /// The Agent switch's help.
    static let agentAbout =
        "Agent: your message becomes a task. Cloak's agent works on it step by step inside its sealed box on this Mac, through Tor. A remote model does the thinking, paid the same way as the chat."

    var name: String {
        switch self {
        case .v: "V"
        case .token: "Token Inference"
        case .near: "NEAR Private AI"
        case .llama: "Local Llama"
        }
    }

    /// Its symbol, here and in the chat list, which marks every chat but
    /// V's.
    var symbol: String {
        switch self {
        case .v: "theatermasks"
        case .token: "dollarsign.circle"
        case .near: "cpu"
        case .llama: "laptopcomputer"
        }
    }

    /// Its help: its name, then what it does and who pays, in one sentence
    /// or two.
    var about: String {
        switch self {
        case .v: "V: reworded on this Mac and sent through Tor. Each request is paid with a new key, from a deposit of ETH."
        case .token: "Token Inference: reworded on this Mac and sent through Tor, paid with USDC.e on Tempo from one wallet on this Mac."
        case .near: "NEAR Private AI: sent as you wrote it once NEAR's hardware check passes, paid by your NEAR key."
        case .llama: "Local Llama: the model on this Mac answers, nothing is sent and there's nothing to pay."
        }
    }

    /// What pays for it, on the Modes page.
    var paidWith: String {
        switch self {
        case .v: "ETH on Ethereum"
        case .token: "USDC.e on Tempo"
        case .near: "A NEAR key from cloud.near.ai"
        case .llama: "Nothing to pay"
        }
    }

    /// What Cloak does in it, on the Modes page, a short line each.
    var lines: [String] {
        switch self {
        case .v:
            [
                "Each message is reworded on this Mac, and you see both.", "Sent through Tor.",
                "Each request is paid from your deposit with a new key.", "Cards aren't accepted.",
                "With Agent on, a message becomes a task.",
            ]
        case .token:
            [
                "Each message is reworded on this Mac, and you see both.", "Sent through Tor.",
                "One wallet pays for every request, so the provider can link your chats.", "Cards aren't accepted.",
                "With Agent on, a message becomes a task.",
            ]
        case .near:
            ["Each message goes to NEAR as you wrote it.", "Sent once NEAR's hardware check passes.", "Through Tor when you turn it on."]
        case .llama:
            ["The model on this Mac answers.", "Nothing is sent.", "No need to start Cloak.", "Answers are simpler than a remote model's."]
        }
    }

    /// Where it comes from, with a link to its X post, under its column.
    var credit: LocalizedStringKey? {
        switch self {
        case .v: "Inspired by Vitalik's [X post](https://x.com/VitalikButerin/status/2111046730959433793) about his preferred AI usage."
        case .token: nil
        case .near: "Cloak is an alternate client to NEAR's own official one. [X post](https://x.com/NEARProtocol/status/2121041723992216043)"
        case .llama: "Cloak is an alternate client to llama.cpp's own official one. [X post](https://x.com/ggerganov/status/2121246103312212124)"
        }
    }
}

/// The modes side by side, a column each: its symbol and name, what pays
/// for it, and what Cloak does in it, with where it comes from under the
/// column. Pressing a column makes the new chat that mode and closes the
/// page. Shown on the first launch, and from Details and Chat's Modes
/// button; it starts nothing.
private struct ModesPage: View {
    let chat: Chat

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Modes")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 12) {
                ForEach(Chat.Kind.modes, id: \.self) { mode in
                    VStack(alignment: .leading, spacing: 8) {
                        ModeColumn(mode: mode, chosen: chat.kind == mode) {
                            chat.kind = mode
                            chat.newConversation()
                            chat.showingModes = false
                        }
                        if let credit = mode.credit {
                            Text(credit)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: 176)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Cloak lives in the menu bar and stays paused until you press Start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Button("Close") { chat.showingModes = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }
}

/// One mode's column on the Modes page, the whole of it a button: the
/// chosen mode's has the accent edge, and the help is the mode's own.
private struct ModeColumn: View {
    let mode: Chat.Kind
    let chosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.name)
                        .font(.headline)
                    Label(mode.paidWith, systemImage: "creditcard")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .help("Paid with")
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(mode.lines, id: \.self) { line in
                        Text(line)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: chosen ? 2 : 1))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .hover(RoundedRectangle(cornerRadius: 12))
        .help(mode.about)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Why a NEAR message stopped, in plain words, and whether it may have
/// reached NEAR.
private struct NearStopRow: View {
    let stop: NearStop
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.title)
                    .fontWeight(.medium)
                Text(stop.words)
                    .foregroundStyle(.secondary)
                Text(stop.sent ? "Your message may have reached NEAR. Sending again may be charged twice." : "Nothing was sent.")
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

/// One switch, as a small glass pill: a dot, filled while on and hollow
/// while off, then its symbol; read by VoiceOver as a switch with its name
/// and state. Its help says what the switch controls. One with `fixed`
/// can't be changed here: its symbol is dimmed, and a press shows those
/// words, why.
private struct SwitchPill: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    let help: String
    var fixed: String?
    @State private var explaining = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if fixed == nil { isOn.toggle() } else { explaining = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "circle.fill" : "circle")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(isOn ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                Image(systemName: symbol)
                    .foregroundStyle(fixed == nil ? HierarchicalShapeStyle.primary : .secondary)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // Before the glass, so the hover lies on it rather than behind it.
        .hover(Capsule())
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isOn)
        .popover(isPresented: $explaining, arrowEdge: .top) {
            Text(fixed ?? "")
                .font(.callout)
                .padding(12)
        }
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .disabled(fixed != nil)
                .accessibilityHint(fixed ?? "")
        }
        .help(help)
    }
}

/// Cloak's state while it is not running, as its symbol, and Start; why
/// rewording, sending as written or the agent waits is the symbol's help
/// and what VoiceOver reads first. Without the model, the way to its
/// download in Details takes the place of Start; while Cloak starts or
/// stops, a spinner does. A failure says why in words, beside Start.
private struct Waiting: View {
    let supervisor: Supervisor
    /// What waits, as the verb ending each sentence: reword, send or run.
    let to: String
    let showDetails: () -> Void

    var body: some View {
        let phase = supervisor.phase
        let words = text(phase)
        // A failure, a missing model among them, keeps its words on screen;
        // the rest are help.
        let failed = if case .needsAttention = phase { true } else { false }
        HStack(spacing: 4) {
            Image(systemName: phase.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
                .help(words)
                .accessibilityHidden(true)
            if failed {
                Text(words)
                    .accessibilityHidden(true)
                Spacer()
            }
            switch phase {
            case .needsAttention(.modelMissing):
                Button("Download Model…", action: showDetails)
            case .paused, .ready, .needsAttention:
                SymbolButton("Start", symbol: "play.fill") { supervisor.send(.start) }
            case .preparing, .stopping, .running:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .help(words)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        // The sentence, read once, then the button.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(words)
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

/// Why a Local Llama chat can't ask (`Chat.LlamaBlock`), and the way on:
/// for the model that rewords, its download in Details; for any other, the
/// Local Llama settings, to download it or choose another. A Mac that can't
/// run the model that rewords can run none, so that stop has no button.
private struct LlamaStop: View {
    let block: Chat.LlamaBlock
    let showDetails: () -> Void
    let showLlamaSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(block.words)
            Spacer()
            switch block {
            case .missing(let download):
                Button(
                    download.isUnderWay ? "Downloading Model…" : "Download Model…",
                    action: download.rewords ? showDetails : showLlamaSettings)
            case .mac(let download) where download.rewords:
                EmptyView()
            case .unknown, .mac:
                Button("Choose Model…", action: showLlamaSettings)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var symbol: String {
        switch block {
        case .missing: "arrow.down.circle"
        case .unknown, .mac: "laptopcomputer"
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
                .hover(Circle(), outset: 4)
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

extension NearStop {
    var title: String {
        switch kind {
        case .line: "Cloak error"
        case .request: "Can't send"
        case .fetch: "No proof"
        case .refused: "Proof refused"
        case .connect: "No connection"
        case .pin: "Server changed"
        case .send: "Interrupted"
        case .status:
            switch code {
            case 401, 403: "Key refused"
            case 429: "Too many"
            default: "NEAR error"
            }
        case .reply: "Answer refused"
        case .helper: "Damaged"
        case .ended: "Stopped"
        case .key: "Key unreadable"
        case .signin: "Not signed in"
        case .claim: "No claim"
        }
    }

    var words: String {
        switch kind {
        case .line: "Cloak's request wasn't formed right."
        case .request: "This message can't go as it is."
        case .fetch: "Cloak couldn't fetch NEAR's proof. Try again."
        case .refused: "NEAR's servers don't match what this version of Cloak accepts. Update Cloak."
        case .connect: "The proof passed, but Cloak couldn't connect to NEAR."
        case .pin: "NEAR answered from a server other than the one checked."
        case .send: "The connection dropped before NEAR's answer came."
        case .status:
            switch code {
            case 401, 403: "NEAR didn't accept your key. Replace it in Settings."
            case 429: "NEAR is limiting your account. Wait, then send again."
            default: "NEAR answered with error \(code ?? 0)."
            }
        case .reply: "NEAR's answer didn't open, so it isn't shown."
        case .helper: "Reinstall Cloak."
        case .ended: "The part of Cloak that talks to NEAR quit."
        case .key: "The keychain didn't give Cloak your NEAR key."
        case .signin: "The sign-in in your browser didn't finish."
        case .claim: "The commons didn't give Cloak a claim to upload with, so nothing went."
        }
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

extension AnswerStop {
    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .interrupted: "Interrupted"
        case .tooLong: "Too long"
        case .failed: "No answer"
        }
    }

    var words: String? {
        switch self {
        case .stopped: nil
        case .interrupted: "Cloak started or stopped while the model was answering. Ask again."
        case .tooLong: "This chat is too long for the model on this Mac. Start a new chat."
        case .failed(let reason): "\(reason.title) Ask again."
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
