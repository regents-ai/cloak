import AppKit
import CloakChat
import CloakControl
#if DARKBLOOM
import CloakDarkbloom
import IOKit.ps
#endif
import CloakDoor
import CloakSupervisor
import os
import SwiftUI
import WidgetKit

/// The menu-bar app: one supervisor, each model's download, its menu, its
/// Chat, Agents, Details and Settings windows, the quick prompt,
/// Chat's Modes page on the first launch, NEAR mode's helper, the one way to
/// V's payer, the door other apps and the agent in the guest send through
/// while Cloak is Running, its AppleScript
/// commands (`StartCommand` and the others), the control channel `cloak`
/// uses to drive the same supervisor, and its updater (`Updates`).
@main
struct RegentsCloakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    // The menu is AppKit's (`StatusMenu`), and the Settings window is the
    // app's own (`SettingsView`); this scene shows nothing. Command-comma
    // opens Settings while one of the app's windows is in front, and these
    // menu commands are indexed by macOS 26/27 Spotlight search.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Credits & Open Source…") { app.showCredits() }
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { app.showSettings() }
                        .keyboardShortcut(",")
                }
                CommandGroup(replacing: .newItem) {
                    Button("New Private Chat") { app.openNewChat(mode: nil) }
                        .keyboardShortcut("n")
                    Divider()
                    Button("Local Mode") { app.openNewChat(mode: .llama) }
                        .keyboardShortcut("1")
                    Button("NEAR AI Gateway") { app.openNewChat(mode: .near) }
                        .keyboardShortcut("2")
                        .disabled(!AppSettings.standard.securityProfile.allowsNear)
                    Button("Token Inference") { app.openNewChat(mode: .token) }
                        .keyboardShortcut("3")
                        .disabled(!AppSettings.standard.securityProfile.allowsTokenInference)
                    Button("zkAPI Anon Inference") { app.openNewChat(mode: .v) }
                        .keyboardShortcut("4")
                        .disabled(!AppSettings.standard.securityProfile.allowsZkAPI)
                }
                CommandMenu("Cloak") {
                    Button(app.supervisor.phase == .running ? "Pause Cloak" : "Start Cloak") {
                        app.handleWidgetCommand(app.supervisor.phase == .running ? .pause : .start)
                    }
                    .keyboardShortcut("s")
                    .disabled(!AppSettings.standard.securityProfile.allowsAnyCloud && app.supervisor.phase != .running)
                    Button("Toggle Cover Traffic") { app.handleWidgetCommand(.toggleCover) }
                        .disabled(!AppSettings.standard.securityProfile.allowsAnyCloud || AppSettings.standard.securityProfile.enforcesTorAndCover)
                    Divider()
                    Button("Funds…") { app.showFunds() }
                        .disabled(!AppSettings.standard.securityProfile.allowsAnyCloud)
                    Button("Take a Tour…") { app.showTour() }
                        .keyboardShortcut("/")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's one delegate, for its AppleScript commands: SwiftUI puts
    /// its own in `NSApp.delegate`.
    private(set) static var current: AppDelegate!

    let supervisor = Launch.supervisor
    /// One for each model that answers Local Llama chats, smallest first.
    let downloads = Launch.manifest.answerModels.map { ModelDownload(model: $0, manifest: Launch.manifest, layout: Launch.layout) }
    /// Optional 44 MB uncensored LoRA adapter downloads, keyed by adapter name.
    let adapterDownloads: [String: ModelDownload] = {
        var map: [String: ModelDownload] = [:]
        for model in Launch.manifest.answerModels {
            if let adapter = model.unfilteredLora, map[adapter.name] == nil {
                map[adapter.name] = ModelDownload(adapter: adapter, manifest: Launch.manifest, layout: Launch.layout)
            }
        }
        return map
    }()
    /// The download of the model that rewords, which every Start needs: the
    /// one the menu and Details show.
    var download: ModelDownload { downloads.first(where: \.rewords)! }
    /// NEAR mode's helper, pinned in the manifest; it starts at the first
    /// check or message.
    let near: Near = {
        let near = Launch.layout.near(Launch.manifest)
        return Near(helper: near.helper, sha256: near.sha256)
    }()
    /// Made at the first show of Chat or Settings, or the quick prompt's
    /// first Return.
    private lazy var nearMode = NearMode(near: near, supervisor: supervisor, settings: .standard)
    private let menuBarIndicator = MenuBarIndicator()
    /// Made at its window's first show or the quick prompt's first Return.
    private var madeChat: Chat?
    private var conversations: Chat {
        if let madeChat { return madeChat }
        let chat = Chat(
            supervisor: supervisor, settings: .standard, folder: Launch.layout.conversations, wallet: Launch.layout.wallet,
            queue: Launch.payQueue, door: door, nearMode: nearMode, downloads: downloads, adapterDownloads: adapterDownloads)
        chat.onAnswerArrived = { [weak self] _ in
            guard let self else { return }
            if !self.chat.isVisibleAndKey {
                self.menuBarIndicator.hasUnreadAnswer = true
            }
        }
        madeChat = chat
        return chat
    }
    /// Something a restart would cut is under way, the one answer to it: a
    /// request at the door; in Chat, a message being reworded, sent or
    /// answered on this Mac, or an agent's task; with V's wallet or Token
    /// Inference's, a press, a read or money on its way. Before Chat is made
    /// there is none of Chat's.
    private var underWay: Bool {
        door.underWay
            || madeChat.map { chat in
                chat.autoStarting != nil || chat.rewording != nil || !chat.sending.isEmpty || !chat.answering.isEmpty || !chat.agent.runs.isEmpty
                    || chat.payer.working > 0 || chat.payer.reading || chat.payer.moving
                    || chat.wallet.working > 0 || chat.wallet.presence == .creating
                    || chat.veniceMode.working > 0 || !chat.veniceMode.partial.isEmpty
            } == true
    }
    private lazy var chat: AppWindow = {
        let window = AppWindow { [unowned self] in
            #if DARKBLOOM
            let showServing: (() -> Void)? = { self.showDarkbloom() }
            #else
            let showServing: (() -> Void)? = nil
            #endif
            return ChatView.window(
                conversations, showDetails: { self.showDetails() }, showAgents: { self.showAgents() },
                showNearSettings: { self.showSettings(on: .near) }, showLlamaSettings: { self.showSettings(on: .llama) },
                showLocalAccessSettings: { self.showSettings(on: .localAccess) },
                showAdvancedSettings: { self.showSettings(on: .advanced) },
                showServingSettings: showServing)
        }
        window.onBecomeKey = { [weak self] in
            self?.menuBarIndicator.hasUnreadAnswer = false
        }
        window.onWillClose = { [weak self] in
            self?.madeChat?.voice.stopAll()
        }
        return window
    }()
    #if DARKBLOOM
    /// Made at its window's first show; it follows Darkbloom only while the
    /// Inference Serving Settings tab is open.
    private var madeDarkbloomMode: DarkbloomMode?
    private var darkbloomMode: DarkbloomMode {
        if let madeDarkbloomMode { return madeDarkbloomMode }
        let manifest = Launch.manifest
        let settings = AppSettings.standard
        let mode = DarkbloomMode(parts: DarkbloomMode.Parts(
            cloakMemory: {
                let chosen = manifest.answerModels.first { $0.name == settings.answerModel && $0.name != manifest.model }
                return manifest.cloakMemory + (chosen?.memory ?? 0)
            },
            openURL: { url in
                NSWorkspace.shared.open(url)
            },
            qosPolicy: { AppSettings.servingQoSPolicy(in: .standard) },
            hostCondition: { AppDelegate.liveServingHostCondition() }
        ))
        madeDarkbloomMode = mode
        return mode
    }

    private nonisolated static func liveServingHostCondition() -> ServingHostCondition {
        var onBattery = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        {
            for source in sources {
                if let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                    let state = desc[kIOPSPowerSourceStateKey as String] as? String,
                    state == (kIOPSBatteryPowerValue as String)
                {
                    onBattery = true
                    break
                }
            }
        }
        let thermal = ServingHostCondition.ThermalLevel(ProcessInfo.processInfo.thermalState)
        let hour = Calendar.current.component(.hour, from: .now)
        return ServingHostCondition(onBattery: onBattery, thermal: thermal, hour: hour)
    }

    func showDarkbloom() {
        showSettings(on: .serving)
        publishWidgetSnapshot()
    }
    #endif
    private let settingsSelection = SettingsView.Selection()
    private lazy var settings: AppWindow = {
        let window = AppWindow { [unowned self, supervisor, prompt, door, updates, nearMode, download, downloads, adapterDownloads, settingsSelection] in
            let chat = self.conversations
            #if DARKBLOOM
            return SettingsView.window(
                .standard, prompt: prompt, supervisor: supervisor, door: door, updates: updates, near: nearMode,
                wallet: chat.wallet, veniceMode: chat.veniceMode, payer: chat.payer,
                download: download, downloads: downloads, adapterDownloads: adapterDownloads,
                darkbloom: self.darkbloomMode,
                openDoor: { self.turnDoor() }, showChat: { self.showChat() }, showFunds: { self.showFunds() }, showTour: { self.showTour() },
                selection: settingsSelection)
            #else
            return SettingsView.window(
                .standard, prompt: prompt, supervisor: supervisor, door: door, updates: updates, near: nearMode,
                wallet: chat.wallet, veniceMode: chat.veniceMode, payer: chat.payer,
                download: download, downloads: downloads, adapterDownloads: adapterDownloads,
                openDoor: { self.turnDoor() }, showChat: { self.showChat() }, showFunds: { self.showFunds() }, showTour: { self.showTour() },
                selection: settingsSelection)
            #endif
        }
        #if DARKBLOOM
        window.onWillClose = { [weak self] in
            self?.madeDarkbloomMode?.close()
        }
        window.onBecomeKey = { [weak self] in
            guard let self, self.settingsSelection.pane == .serving else { return }
            self.madeDarkbloomMode?.open()
        }
        #endif
        return window
    }()
    private lazy var credits = AppWindow { CreditsView.window() }
    private lazy var prompt = QuickPrompt(settings: .standard) { [unowned self] text in
        conversations.compose(text)
        showChat()
    }
    private var menu: StatusMenu?
    /// Made at launch, with the menu.
    private lazy var updates = Updates()
    lazy var door: Door = {
        let supervisor = Launch.supervisor, conversations = Launch.layout.conversations, manifest = Launch.manifest, near = self.near
        return Door(
            file: Launch.layout.agents, wallet: Launch.layout.wallet,
            parts: Door.Parts(
                reword: { texts throws(RewriteStop) in try await supervisor.rewrite(texts) },
                queue: Launch.payQueue,
                exchange: { request, keep in try await supervisor.exchange(request: request, keep: keep) },
                wallet: { try await WalletKeychain.address() },
                key: { try WalletKeychain.key() },
                sealing: {
                    try await ConversationStore.key(
                        for: conversations,
                        alsoSealed: [Launch.layout.wallet.appending(path: "deposit"), Launch.layout.agents],
                        find: Keychain.find, make: Keychain.make)
                },
                macPayment: { AppSettings.doorPayment(in: .standard).payment },
                macRoute: { AppSettings.doorPayment(in: .standard).macRoute },
                routeAllowed: { route in AppSettings.doorRouteRefusal(for: route, in: .standard) },
                localModels: {
                    if let ext = AppSettings.externalLocalSelection(in: .standard) {
                        let payload: [String: Any] = [
                            "object": "list",
                            "data": [["id": ext.modelID, "object": "model", "owned_by": ext.serverName]],
                        ]
                        return try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
                    }
                    let chatModels = manifest.answerModels.filter { $0.name != manifest.model }
                    let chosenName = UserDefaults.standard.string(forKey: AppSettings.Key.answerModel.rawValue)
                    let ordered: [Manifest.Model] = {
                        if let chosenName, let match = chatModels.first(where: { $0.name == chosenName }) {
                            return [match] + chatModels.filter { $0.name != chosenName }
                        }
                        let vmlx = chatModels.filter { $0.engine == .vmlx }
                        let rest = chatModels.filter { $0.engine != .vmlx }
                        return vmlx.reversed() + rest.reversed()
                    }()
                    let items: [[String: Any]] = ordered.map { model in
                        ["id": model.name, "object": "model", "owned_by": "cloak-local"]
                    }
                    let payload: [String: Any] = ["object": "list", "data": items]
                    return try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
                },
                localComplete: { body in
                    if let ext = AppSettings.externalLocalSelection(in: .standard) {
                        return try await LocalServerDiscovery.complete(baseURL: ext.baseURL, modelID: ext.modelID, body: body)
                    }
                    let (requestedModel, messages) = AppDelegate.parseOpenAILocalMessages(from: body)
                    let chatModels = manifest.answerModels.filter { $0.name != manifest.model }
                    let chosenName = UserDefaults.standard.string(forKey: AppSettings.Key.answerModel.rawValue)
                    guard let model = (requestedModel.flatMap { id in chatModels.first(where: { $0.name == id }) })
                        ?? (chosenName.flatMap { id in chatModels.first(where: { $0.name == id }) })
                        ?? chatModels.last(where: { $0.engine == .vmlx })
                        ?? chatModels.last
                    else {
                        throw LocalServerDiscovery.DiscoveryError.unreachable("No local model is configured in Settings → Local Models.")
                    }
                    let useUnfiltered = UserDefaults.standard.bool(forKey: AppSettings.Key.unfilteredLocal.rawValue)
                    let lora = useUnfiltered ? model.unfilteredLora : nil
                    let effort = AppSettings.localReasoningEffort(in: .standard)
                    let reply = try await supervisor.answer(messages, with: model, lora: lora, reasoningEffort: effort)
                    let payload: [String: Any] = [
                        "id": "chatcmpl-\(UUID().uuidString.prefix(12).lowercased())",
                        "object": "chat.completion",
                        "created": Int(Date.now.timeIntervalSince1970),
                        "model": model.name,
                        "choices": [[
                            "index": 0,
                            "message": ["role": "assistant", "content": reply.text],
                            "finish_reason": "stop",
                        ]],
                    ]
                    return try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
                },
                nearModels: {
                    let payload: [String: Any] = [
                        "object": "list",
                        "data": [["id": Near.model, "object": "model", "owned_by": "near-ai"]],
                    ]
                    return try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
                },
                nearComplete: { body in
                    let (route, proofAge): (NearRoute?, ProofFreshness) = await MainActor.run {
                        let settings = AppSettings.standard
                        let resolved: NearRoute?
                        if settings.nearTor {
                            resolved = supervisor.torSocket.map {
                                .tor(socket: $0, near: Chat.newIdentity(), intel: Chat.newIdentity())
                            }
                        } else {
                            resolved = .direct
                        }
                        return (resolved, settings.proofFreshness)
                    }
                    guard let route else {
                        throw LocalServerDiscovery.DiscoveryError.unreachable("Start Cloak to route NEAR AI Gateway through Tor, or turn off Tor for NEAR in Settings.")
                    }
                    return try await near.complete(route: route, proofAge: proofAge, key: { try NearKeychain.key() }, body: body)
                },
                veniceModels: {
                    let (useTor, allTiers, identity) = await MainActor.run {
                        (AppSettings.standard.tokenTor, AppSettings.standard.veniceAllTiers, Chat.newIdentity())
                    }
                    let transport = Remote.veniceTransport(identity: identity) {
                        if useTor {
                            try await supervisor.venice($0)
                        } else {
                            try await supervisor.veniceDirect($0)
                        }
                    }
                    let models = try await Venice.models(transport: transport)
                        .filter { !$0.remapped && !$0.offline && ($0.tier.isVenicePrivate || allTiers) }
                    let items: [[String: Any]] = models.map { model in
                        [
                            "id": model.id,
                            "object": "model",
                            "owned_by": "venice-ai",
                            "pricing": ["input": model.input, "output": model.output],
                        ]
                    }
                    let payload: [String: Any] = ["object": "list", "data": items]
                    return try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
                },
                veniceComplete: { body, identity in
                    let (useTor, pays) = await MainActor.run {
                        (AppSettings.standard.tokenTor, AppSettings.standard.venicePays)
                    }
                    let exchange: Exchange = { request, keep in
                        if useTor {
                            try await supervisor.exchange(request: request, keep: keep)
                        } else {
                            try await supervisor.exchangeDirect(request: request, keep: keep)
                        }
                    }
                    let transport = Remote.veniceTransport(identity: identity) {
                        if useTor {
                            try await supervisor.venice($0)
                        } else {
                            try await supervisor.veniceDirect($0)
                        }
                    }
                    let auth: VeniceAuth
                    switch pays {
                    case .key:
                        auth = .key(try ProviderKeychain.venice.key())
                    case .wallet:
                        guard let address = try await VeniceWalletKeychain.address() else {
                            throw LocalServerDiscovery.DiscoveryError.unreachable("Create and fund your Venice Base USDC wallet in Funds first.")
                        }
                        auth = .wallet(Remote.veniceSigner(address: address, key: { try VeniceWalletKeychain.key() }, exchange: exchange))
                    }
                    return try await Venice(auth: auth, transport: transport).complete(body: body)
                },
                preferredVeniceModel: {
                    guard let data = UserDefaults.standard.data(forKey: AppSettings.Key.veniceModel.rawValue),
                        let choice = try? JSONDecoder().decode(VeniceChoice.self, from: data)
                    else { return nil }
                    return choice.id
                },
                preferredModel: { payment in
                    switch payment {
                    case .zkapi:
                        return AppSettings.vModel(in: .standard)
                    case .tempo:
                        return UserDefaults.standard.string(forKey: Wallet.modelKey) ?? Wallet.defaultModel
                    }
                },
                forcedModel: { AppSettings.doorModel(in: .standard) },
                spendLedger: SpendLedger(file: Launch.layout.wallet.appending(path: "spend-receipts.json")),
                spendPolicy: { AppSettings.spendPolicy(in: .standard) },
                privacyPolicy: { AppSettings.doorPrivacyPolicy(in: .standard) }),
            port: { AppSettings.standard.doorPort })
    }()
    /// The door's latest open or close, which the next one waits for, so
    /// the two never cross: the app's own as Cloak starts and stops, and
    /// Agents' Try Again.
    private var doorTurn: Task<Void, Never>?
    private var server: ControlServer?
    private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A write to a worker or a guest connection that has gone must fail
        // (the callers handle that), not end Cloak, as the signal's default
        // would. `cloak-host` and the worker do the same.
        signal(SIGPIPE, SIG_IGN)
        // Help shows after a second's rest on a control, not the system's two.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 1000])
        NSWindow.allowsAutomaticWindowTabbing = false
        Self.current = self
        // With "quit" below, the two ends of a run in the Mac's log: a run
        // with no "quit" ended some other way (`app/log.sh`).
        logger.notice("opened \(Launch.manifest.release, privacy: .public) (\(Launch.manifest.build, privacy: .public))")
        menu = StatusMenu(
            supervisor: supervisor, download: download, settings: .standard,
            indicator: menuBarIndicator,
            showChat: showChat, showFunds: showFunds, showTour: showTour,
            showDetails: showDetails, showSettings: showSettings, checkForUpdates: updates.check,
            submitPrompt: { [unowned self] text in
                conversations.compose(text)
                showChat()
            },
            selectMode: { [unowned self] mode in
                if conversations.isOpen {
                    conversations.selectMode(mode)
                } else {
                    conversations.kind = mode
                }
                publishWidgetSnapshot()
            },
            activeMode: { [unowned self] in
                madeChat?.kind ?? .llama
            })
        if !Places.isDev {
            startWidgetSync()
            registerWidgetCommandObserver()
        }
        // Made now, so the shortcut chosen works from launch.
        _ = prompt
        // The agent's model requests from the guest come in at the door.
        supervisor.door = { [door] socket in door.accept(guest: socket) }
        do {
            server = try ControlServer(path: Places.socket) { [supervisor] request in
                await supervisor.handle(request)
            }
        } catch {
            logger.error("cannot serve the control channel: \(String(describing: error), privacy: .public)")
            Launch.stop("Cloak can't open.", "Quit Cloak, then open it again.")
        }
        // The door is open while Cloak is Running, or immediately when Connected
        // Apps uses a non-VM rail (Local, direct NEAR, or direct Venice); a new port moves it at once.
        Task { [unowned self, supervisor] in
            for await _ in Observations({
                (
                    supervisor.phase == .running,
                    supervisor.phase.state == .stopping,
                    AppSettings.standard.doorPayment,
                    AppSettings.standard.nearTor,
                    AppSettings.standard.tokenTor,
                    AppSettings.standard.securityProfile,
                    AppSettings.standard.doorPort
                )
            }) {
                turnDoor()
            }
        }
        // Cover Traffic toggles live over Tor without restarting Cloak.
        Task { [supervisor] in
            for await _ in Observations({ (supervisor.phase == .running, AppSettings.standard.cover) }) {
                supervisor.syncCover()
            }
        }
        // Enforcing a stricter Security Profile immediately stops disallowed
        // outbound services (Tor/VM in Local Only, network serving outside Private Cloud).
        Task { [unowned self, supervisor] in
            for await profile in Observations({ AppSettings.standard.securityProfile }) {
                if !profile.allowsAnyCloud,
                    supervisor.phase == .running || supervisor.phase.state == .preparing
                {
                    _ = supervisor.send(.pause)
                }
                #if DARKBLOOM
                if !profile.allowsNetworkServing,
                    let dm = self.madeDarkbloomMode,
                    dm.servingMode == .network
                {
                    dm.setServingMode(.localOnly)
                }
                #endif
            }
        }
        // Sleep pauses a run, so a wake finds none running and starts
        // nothing. A worker up for Local Llama chats stays, and rests as
        // ever.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self, supervisor] _ in
            MainActor.assumeIsolated {
                self?.madeChat?.voice.stopAll()
                _ = supervisor.send(.sleep)
            }
        }
        // A minimized window reads "Cloak - Chat" and so on in the Dock;
        // Settings reads "Cloak - Settings" whatever pane it shows. Set as it
        // minimizes, since every change of title resets it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willMiniaturizeNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? ClosingWindow else { return }
            MainActor.assumeIsolated {
                let name = window.contentViewController is NSHostingController<SettingsView> ? "Settings" : window.title
                window.miniwindowTitle = "Cloak - \(name)"
            }
        }
        // Offer to move out of a mounted DMG / Downloads before opening UI.
        if MoveToApplications.promptIfNeeded() { return }

        // Once, on the first launch: open Chat directly on Local mode with the
        // hardware-aware 3-step Welcome Tour (Decision N6b); it starts nothing.
        if !UserDefaults.standard.bool(forKey: Self.welcomed) {
            UserDefaults.standard.set(true, forKey: Self.welcomed)
            if !conversations.recommendedLocalDownload.fits {
                conversations.kind = .near
            }
            conversations.showingTour = true
            showChat()
        } else if AppSettings.standard.depositExpires != nil {
            // Ensure ExpiryGuard is active immediately even when Cloak runs
            // purely in the menu bar without opening Chat or Settings.
            _ = conversations
        }
    }

    /// Reopening Cloak from Spotlight, Finder, or the Dock when no window is
    /// visible opens Chat instead of doing nothing (fixes `LSUIElement`
    /// menu-bar apps feeling unresponsive when the menu icon is behind a notch).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showChat() }
        return true
    }

    /// Handles `cloak://action/<command>` deep links from Control Center controls
    /// and Desktop Widgets. Strictly control-only — never accepts prompt text.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "cloak", url.host == "credits" {
                showCredits()
            } else if let command = WidgetBridge.command(from: url) {
                handleWidgetCommand(command)
            }
        }
    }

    /// Opens a fresh private chat, optionally switching to `mode` if permitted by Security Profile.
    func openNewChat(mode: Chat.Kind?) {
        if let mode {
            let resolved: Chat.Kind = conversations.isModeAllowed(mode) ? mode : .llama
            if conversations.isOpen {
                conversations.selectMode(resolved)
            } else {
                conversations.kind = resolved
            }
        } else if conversations.isOpen {
            conversations.newConversation()
        }
        showChat()
        publishWidgetSnapshot()
    }

    /// Executes a privacy-safe control command from Control Center, Desktop
    /// Widgets, Spotlight App Intents, or the menu bar.
    func handleWidgetCommand(_ command: WidgetCommand) {
        let profile = AppSettings.standard.securityProfile
        switch command {
        case .start:
            guard profile.allowsAnyCloud else { return }
            supervisor.send(.start)
        case .pause:
            supervisor.send(.pause)
        case .toggleTor:
            if supervisor.phase == .running || supervisor.phase.state == .preparing {
                supervisor.send(.pause)
            } else if profile.allowsAnyCloud {
                supervisor.send(.start)
            }
        case .enableCover:
            guard profile.allowsAnyCloud else { return }
            AppSettings.standard.cover = true
        case .disableCover:
            guard !profile.enforcesTorAndCover else { return }
            AppSettings.standard.cover = false
        case .toggleCover:
            guard profile.allowsAnyCloud, !profile.enforcesTorAndCover else { return }
            AppSettings.standard.cover.toggle()
        case .newChat:
            openNewChat(mode: nil)
        case .newLocalChat:
            openNewChat(mode: .llama)
        case .newNearChat:
            openNewChat(mode: .near)
        case .newTokenChat:
            openNewChat(mode: .token)
        case .newAnonChat:
            openNewChat(mode: .v)
        case .openFunds:
            guard profile.allowsAnyCloud else { showSettings(on: .general); return }
            showFunds()
        case .openTour:
            showTour()
        case .openSettings:
            showSettings()
        case .openServing:
            #if DARKBLOOM
            showDarkbloom()
            #else
            showChat()
            #endif
        }
        publishWidgetSnapshot()
    }

    /// Publishes non-sensitive operational status to the shared App Group so
    /// Control Center switches and the Desktop Privacy Posture Widget stay live.
    private func startWidgetSync() {
        publishWidgetSnapshot()
        Task { [unowned self, supervisor, download] in
            for await _ in Observations({
                #if DARKBLOOM
                (
                    supervisor.phase,
                    supervisor.startStep,
                    AppSettings.standard.cover,
                    download.state,
                    self.madeChat?.kind,
                    self.madeChat?.payer.expiry,
                    self.madeDarkbloomMode?.state == .serving,
                    self.madeDarkbloomMode?.snapshot?.liveMetrics?.resolvedTPS,
                    self.madeDarkbloomMode?.snapshot?.liveMetrics?.resolvedRequests
                )
                #else
                (
                    supervisor.phase,
                    supervisor.startStep,
                    AppSettings.standard.cover,
                    download.state,
                    self.madeChat?.kind,
                    self.madeChat?.payer.expiry
                )
                #endif
            }) {
                #if DARKBLOOM
                if let dm = self.madeDarkbloomMode {
                    self.menuBarIndicator.isDarkbloomServing = dm.state == .serving
                }
                #endif
                self.publishWidgetSnapshot()
            }
        }
    }

    private func publishWidgetSnapshot() {
        let phase = supervisor.phase
        let phaseRaw: String = switch phase {
        case .running: "running"
        case .preparing: "preparing"
        case .paused: "paused"
        case .ready: "ready"
        case .stopping: "stopping"
        case .needsAttention: "needsAttention"
        }
        let activeKind = madeChat?.kind ?? .llama
        let activeMode: String = switch activeKind {
        case .llama: "local"
        case .near: "near"
        case .token: "token"
        case .v: "v"
        }
        let localReady = downloads.contains { $0.state == .installed }
        let expiryDays: Int? = madeChat?.payer.expiry.map { expiry in
            max(0, Int(expiry.timeIntervalSinceNow / 86_400))
        }
        #if DARKBLOOM
        let servingActive = madeDarkbloomMode.map { $0.state == .serving }
        let servingModel = madeDarkbloomMode?.recommended?.displayName
        let servingTPS = madeDarkbloomMode?.snapshot?.liveMetrics?.resolvedTPS
        let servingRequests = madeDarkbloomMode?.snapshot?.liveMetrics?.resolvedRequests
        #else
        let servingActive: Bool? = nil
        let servingModel: String? = nil
        let servingTPS: Double? = nil
        let servingRequests: Int? = nil
        #endif
        let snapshot = WidgetSnapshot(
            phaseRaw: phaseRaw,
            phaseTitle: phase.title,
            startStepTitle: phase.state == .preparing ? supervisor.startStep?.menuTitle : nil,
            coverEnabled: AppSettings.standard.cover,
            activeMode: activeMode,
            localReady: localReady,
            anonVExpiryDays: expiryDays,
            servingActive: servingActive,
            servingModel: servingModel,
            servingTPS: servingTPS,
            servingRequests: servingRequests,
            updatedAt: .now
        )
        WidgetBridge.writeSnapshot(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }

    private func registerWidgetCommandObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                Task { @MainActor in
                    guard let command = WidgetBridge.takePendingCommand() else { return }
                    AppDelegate.current?.handleWidgetCommand(command)
                }
            },
            WidgetBridge.darwinCommandNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// The flag in the defaults, set on the first launch.
    private static let welcomed = "welcomed"

    func showChat() {
        menuBarIndicator.hasUnreadAnswer = false
        chat.show()
    }

    /// Chat, with its 3-step Welcome Tour sheet on it.
    func showTour() {
        conversations.showingWallet = false
        conversations.showingTour = true
        chat.show()
    }

    /// Opens the unified Funds sheet over Chat.
    func showFunds() {
        conversations.showingTour = false
        conversations.showingWallet = true
        chat.show()
    }

    func showAgents() {
        showSettings(on: .connectedApps)
    }

    /// Opens the door while Cloak is Running (or while a no-VM rail is active),
    /// or moves it to a new port, and closes it otherwise.
    private func turnDoor() {
        let settings = AppSettings.standard
        let rail = settings.doorPayment
        let noVMRailReady = rail.isAllowed(in: settings.securityProfile) && (
            rail == .local
                || (rail == .near && !settings.nearTor)
                || (rail == .venice && !settings.tokenTor)
        )
        let shouldOpen = supervisor.phase.state != .stopping
            && (supervisor.phase == .running || noVMRailReady)
        doorTurn = Task { [door, last = doorTurn] in
            await last?.value
            if shouldOpen { await door.open() } else { await door.close() }
        }
    }

    /// Converts an OpenAI Chat Completions JSON request into alternating `LocalMessage`s
    /// for Cloak's sandboxed local workers.
    private nonisolated static func parseOpenAILocalMessages(from body: Data) -> (model: String?, messages: [LocalMessage]) {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return (nil, [.user("")])
        }
        let model = root["model"] as? String
        let rawMessages = root["messages"] as? [[String: Any]] ?? []
        var systemParts: [String] = []
        var normalized: [(role: String, text: String)] = []

        for item in rawMessages {
            let role = (item["role"] as? String ?? "user").lowercased()
            let text: String
            if let s = item["content"] as? String {
                text = s
            } else if let parts = item["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                text = ""
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if role == "system" || role == "developer" {
                systemParts.append(trimmed)
                continue
            }
            let mappedRole = (role == "assistant") ? "assistant" : "user"
            if let last = normalized.last, last.role == mappedRole {
                normalized[normalized.count - 1].text += "\n\n" + trimmed
            } else {
                normalized.append((mappedRole, trimmed))
            }
        }

        if !systemParts.isEmpty {
            let prefix = systemParts.joined(separator: "\n\n")
            if let firstUser = normalized.firstIndex(where: { $0.role == "user" }) {
                normalized[firstUser].text = prefix + "\n\n" + normalized[firstUser].text
            } else {
                normalized.append(("user", prefix))
            }
        }
        if normalized.isEmpty {
            normalized.append(("user", "Hello"))
        } else if normalized.last?.role != "user" {
            normalized.append(("user", "Continue."))
        }
        let localMessages: [LocalMessage] = normalized.map { entry in
            entry.role == "assistant" ? .assistant(entry.text) : .user(entry.text)
        }
        return (model, localMessages)
    }

    func showDetails() {
        showSettings(on: .status)
    }

    func showSettings() {
        settings.show()
    }

    func showCredits() {
        credits.show()
    }

    /// Settings, on `pane`.
    func showSettings(on pane: SettingsView.Pane) {
        settingsSelection.pane = pane
        settings.show()
    }

    /// Quit, from the menu or the system, goes through the one shutdown,
    /// and ends once every app with a request under way has been answered.
    /// NEAR mode's helper ends at once, a message under way or not.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        near.stop()
        let pendingDoor = doorTurn
        supervisor.quit { [server, door, logger] in
            server?.close()
            Task {
                await pendingDoor?.value
                await door.close()
                logger.notice("quit")
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

/// What the app needs before it can show anything: its manifest, being the
/// only Regents Cloak running for this user, and its supervisor, which first
/// clears what a killed app left behind.
@MainActor
enum Launch {
    static let manifest: Manifest = {
        do {
            try Places.makeOwnerOnly(Places.control)
            guard try Instance.claim() else { exit(0) }
            return try Manifest.bundled()
        } catch {
            Logger(subsystem: "sh.regents.cloak.app", category: "app").error("cannot open: \(String(describing: error), privacy: .public)")
            stop("Cloak is damaged.", "Reinstall Cloak.")
        }
    }()

    static let layout = Layout(bundle: Bundle.main.resourceURL!, support: Places.support)

    /// The one way to V's payer in the guest, Chat's and the door's, so
    /// their requests take their turns in one queue.
    static let payQueue = PayQueue { [supervisor] ask, payload in try await supervisor.pay(ask, payload) }

    static let supervisor: Supervisor = {
        do {
            return try Supervisor(manifest: manifest, layout: layout, cover: { AppSettings.standard.cover }) {
                AppSettings.freeMemory(in: .standard).after
            }
        } catch {
            Logger(subsystem: "sh.regents.cloak.app", category: "app").error("cannot clear the boot files: \(String(describing: error), privacy: .public)")
            stop("Cloak can't open.", "Quit Cloak, then open it again.")
        }
    }()

    /// Says why the app cannot run, then ends it.
    static func stop(_ message: String, _ remedy: String) -> Never {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = remedy
        NSApp.activate()
        alert.runModal()
        exit(1)
    }
}
