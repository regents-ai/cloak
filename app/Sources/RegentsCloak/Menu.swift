import AppKit
import CloakControl
#if DARKBLOOM
import CloakDarkbloom
#endif
import CloakSupervisor
import Observation

/// The menu-bar item and its menu: the header (the app's name, the state's
/// dot and its line, or a failure with its fix), the way to the model's
/// download while its files are not all in place, Start or Pause, Chat,
/// Agents, Details, Settings, Check for Updates… (`Updates`),
/// Quit, and the release and build. Start, here or in the header, also
/// shows Chat; it is off while Cloak needs attention for a reason a start
/// is certain to stop on again (`Fix.startStops`). Every action
/// but Show in Finder is reachable from the keyboard, since the header's
/// other fixes are also Start or Details. It is AppKit's menu, since a
/// SwiftUI menu holds only plain items and the header is a view of its own.
/// Live visual indicators for the top menu bar icon:
/// - `hasUnreadAnswer`: draws a vivid blue ring around the status badge when a
///   prompt finishes while Chat is not in front.
/// - `isDarkbloomServing`: replaces the static play/pause badge with a gentle
///   animated blooming mark while Darkbloom inference serving is active.
@MainActor
@Observable
final class MenuBarIndicator {
    var hasUnreadAnswer = false
    var isDarkbloomServing = false
}

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let supervisor: Supervisor
    private let download: ModelDownload
    private let settings: AppSettings
    private let indicator: MenuBarIndicator
    private let showChat: () -> Void
    private let showFunds: () -> Void
    private let showTour: () -> Void
    private let showDetails: () -> Void
    private let showSettings: () -> Void
    private let checkForUpdates: () -> Void
    // As wide as its icon, which is wider than the bar is tall.
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let header = NSMenuItem()
    private let headerView = MenuHeaderView()
    private var panelController: MenuPanelController?
    private var rightClickMonitor: Any?
    private var bloomAnimationTask: Task<Void, Never>?
    private var bloomFrame = 0
    private var open = false

    init(
        supervisor: Supervisor, download: ModelDownload, settings: AppSettings,
        indicator: MenuBarIndicator,
        showChat: @escaping () -> Void, showFunds: @escaping () -> Void,
        showTour: @escaping () -> Void, showDetails: @escaping () -> Void,
        showSettings: @escaping () -> Void, checkForUpdates: @escaping () -> Void,
        submitPrompt: @escaping (String) -> Void,
        selectMode: @escaping (Chat.Kind) -> Void,
        activeMode: @escaping () -> Chat.Kind
    ) {
        self.supervisor = supervisor
        self.download = download
        self.settings = settings
        self.indicator = indicator
        self.showChat = showChat
        self.showFunds = showFunds
        self.showTour = showTour
        self.showDetails = showDetails
        self.showSettings = showSettings
        self.checkForUpdates = checkForUpdates
        super.init()
        header.view = headerView
        headerView.act = { [unowned self] fix in
            menu.cancelTracking()
            switch fix {
            case .start:
                supervisor.send(.start)
                showChat()
            case .download: showDetails()
            case .repair:
                download.repair()
                showDetails()
            case .showModel: Fix.showModel()
            }
        }
        menu.autoenablesItems = false
        menu.delegate = self
        item.autosaveName = Places.isDev ? "sh.regents.cloak.dev.statusItem" : "sh.regents.cloak.statusItem"
        item.button?.image = MenuBarIcon.image(supervisor.phase)
        if Places.isDev {
            item.button?.title = " DEV"
            item.button?.imagePosition = .imageLeading
            item.button?.toolTip = "Cloak Dev (isolated local test build)"
        }
        if #available(macOS 27.0, *) {
            #if DARKBLOOM
            let actions = MenuPanelController.Actions(
                showChat: showChat, showFunds: showFunds, showTour: showTour,
                showDetails: showDetails, showSettings: showSettings, checkForUpdates: checkForUpdates,
                submitPrompt: submitPrompt, selectMode: selectMode, activeMode: activeMode,
                showDarkbloom: { AppDelegate.current.showDarkbloom() }
            )
            #else
            let actions = MenuPanelController.Actions(
                showChat: showChat, showFunds: showFunds, showTour: showTour,
                showDetails: showDetails, showSettings: showSettings, checkForUpdates: checkForUpdates,
                submitPrompt: submitPrompt, selectMode: selectMode, activeMode: activeMode
            )
            #endif
            panelController = MenuPanelController(
                supervisor: supervisor, download: download, settings: settings, actions: actions)
            item.expandedInterfaceDelegate = self
            rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, let button = self.item.button, event.window === button.window else { return event }
                // Dispatch out of the NSEvent monitor before running `NSMenu.popUp`,
                // which starts a nested modal tracking runloop that freezes/blocks
                // event delivery if invoked synchronously inside a local monitor.
                Task { @MainActor [weak self, weak button] in
                    guard let self, let button else { return }
                    self.showContextMenu(below: button)
                }
                return nil
            }
        } else {
            item.menu = menu
        }
        // The menu lasts as long as the app, and so does this.
        Task {
            for await watched in Observations({
                Watched(
                    phase: supervisor.phase, startStep: supervisor.startStep,
                    resting: supervisor.resting, download: download.state,
                    nearTor: settings.nearTor,
                    unread: indicator.hasUnreadAnswer, darkbloomServing: indicator.isDarkbloomServing)
            }) {
                self.syncBloomAnimation(serving: watched.darkbloomServing)
                self.renderIcon()
                if open { rebuild() }
            }
        }
        #if DARKBLOOM
        // Lightweight background poll so the animated bloom icon stays accurate
        // even when Settings → Inference Serving is closed.
        Task { [weak self] in
            while !Task.isCancelled {
                let serving = await Self.probeDarkbloomServing()
                guard let self else { break }
                if self.indicator.isDarkbloomServing != serving {
                    self.indicator.isDarkbloomServing = serving
                }
                try? await Task.sleep(for: .seconds(8))
            }
        }
        #endif
    }

    private func renderIcon() {
        item.button?.image = MenuBarIcon.image(
            supervisor.phase,
            unread: indicator.hasUnreadAnswer,
            darkbloomServing: indicator.isDarkbloomServing,
            bloomFrame: bloomFrame,
            appearance: item.button?.effectiveAppearance)
    }

    private func syncBloomAnimation(serving: Bool) {
        guard serving, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            bloomAnimationTask?.cancel()
            bloomAnimationTask = nil
            bloomFrame = 0
            return
        }
        guard bloomAnimationTask == nil else { return }
        bloomAnimationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(140))
                guard let self, !Task.isCancelled, self.indicator.isDarkbloomServing else { break }
                self.bloomFrame = (self.bloomFrame + 1) % MenuBarIcon.bloomFrameCount
                self.renderIcon()
            }
        }
    }

    #if DARKBLOOM
    @concurrent private static func probeDarkbloomServing() async -> Bool {
        // Read ~/.darkbloom/daemon-state.json directly (< 0.1 ms) instead of
        // polling GET /control/v1/state (~2.5s serialized RPC on darkbloom
        // desktop serve), which otherwise stalls Settings → Inference Serving.
        return Darkbloom.isDaemonAlive()
    }
    #endif

    /// What the menu shows that can change while it is open.
    private struct Watched: Equatable {
        var phase: Phase
        var startStep: Supervisor.StartStep?
        var resting: Bool
        var download: ModelDownload.State
        var nearTor: Bool
        var unread: Bool
        var darkbloomServing: Bool
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The model's files can change while the menu is closed.
        download.refresh()
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        open = true
    }

    func menuDidClose(_ menu: NSMenu) {
        open = false
        if #available(macOS 27.0, *), panelController != nil {
            item.menu = nil
            item.expandedInterfaceDelegate = self
        }
    }

    func showContextMenu(below button: NSStatusBarButton) {
        if #available(macOS 27.0, *) {
            item.expandedInterfaceSession?.cancel()
            item.expandedInterfaceDelegate = nil
        }
        // Attach natively to the status item and trigger a click so AppKit
        // anchors the NSMenu directly below the menu bar without the top
        // scroll-chevron clipping bug caused by `NSMenu.popUp(positioning:at:in:)`.
        item.menu = menu
        button.performClick(nil)
    }

    private func rebuild() {
        let phase = supervisor.phase
        let shown = MenuHeader(phase: phase, startStep: supervisor.startStep, resting: supervisor.resting, download: download)
        headerView.show(shown)
        menu.removeAllItems()
        menu.addItem(header)
        // The download itself, and what is said before it starts, are in
        // Details. A failure that the download fixes offers it in its place.
        if download.state != .installed, !shown.offersDownload {
            menu.addItem(
                Action(download.isUnderWay ? "Downloading Model…" : "Download Model…", symbol: "arrow.down.circle", run: showDetails))
        }
        menu.addItem(.separator())
        switch phase {
        case .preparing, .running:
            menu.addItem(Action("Pause", symbol: "pause.fill", key: "p") { [supervisor] in supervisor.send(.pause) })
        case .stopping:
            let start = Action("Start", symbol: "play.fill") {}
            start.isEnabled = false
            menu.addItem(start)
        case .paused, .ready, .needsAttention:
            let start = Action("Start", symbol: "play.fill", key: "s") { [supervisor, showChat] in
                supervisor.send(.start)
                showChat()
            }
            // The header above says why.
            if case .needsAttention(let reason) = phase { start.isEnabled = !Fix.startStops(for: reason, download: download) }
            menu.addItem(start)
        }
        menu.addItem(Action("Chat", symbol: "bubble.left", run: showChat))
        menu.addItem(Action("Funds", symbol: "creditcard", run: showFunds))
        #if DARKBLOOM
        menu.addItem(Action("Inference Serving", symbol: "server.rack") { AppDelegate.current.showDarkbloom() })
        #endif
        menu.addItem(Action("Settings…", symbol: "gearshape", key: ",", run: showSettings))
        menu.addItem(.separator())
        menu.addItem(Action("Take a Tour…", symbol: "sparkles", run: showTour))
        menu.addItem(Action("Check for Updates…", symbol: "arrow.down.circle", run: checkForUpdates))
        menu.addItem(Action("Quit", symbol: "power", key: "q") { NSApp.terminate(nil) })
        menu.addItem(footer)
    }

    /// The release and build in small secondary text, so a stale build is
    /// not taken for a fault.
    private lazy var footer: NSMenuItem = {
        let text = "\(supervisor.manifest.release) · \(supervisor.manifest.build)"
        let footer = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        footer.attributedTitle = NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        footer.isEnabled = false
        return footer
    }()
}

@available(macOS 27.0, *)
extension StatusMenu: NSStatusItemExpandedInterfaceDelegate {
    nonisolated func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) {
        MainActor.assumeIsolated {
            if let event = NSApp.currentEvent,
                event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control),
                let button = item.button
            {
                item.expandedInterfaceSession?.cancel()
                Task { @MainActor [weak self, weak button] in
                    guard let self, let button else { return }
                    self.showContextMenu(below: button)
                }
                return
            }
            panelController?.show(below: item) { [weak self] in
                self?.item.expandedInterfaceSession?.cancel()
            }
        }
    }

    nonisolated func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        MainActor.assumeIsolated {
            panelController?.hide(animated: animated)
        }
    }
}

/// A menu item that runs its closure when chosen. Its symbol shows where the
/// Mac shows symbols in menus: macOS 26 does, and macOS 27 hides them, which
/// is left to the Mac (`preferredImageVisibility` stays automatic).
@MainActor
private final class Action: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, symbol: String, key: String = "", run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(choose), keyEquivalent: key)
        // The words name it; the symbol adds nothing to read aloud.
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("not made from a file")
    }

    @objc private func choose() {
        // Run after NSMenu exits its modal tracking runloop so activation
        // policy changes and window presentation never get swallowed.
        Task { @MainActor in
            self.run()
        }
    }
}

/// What the menu's header says. Its dot is the state now, grey while Cloak
/// starts or stops, and its line says the state now, Starting, Stopping or
/// Restarting meanwhile. A failure takes the line, with its remedy
/// and its one fix (`Fix`), once Cloak has stopped for it.
struct MenuHeader: Equatable {
    enum Dot: Equatable {
        case running, stopped, attention, changing
    }

    enum Line: Equatable {
        /// The state's word, with what the model is doing beside it.
        case state(String, unloaded: Bool, downloading: Bool)
        case failure(Reason, fix: Fix?)
    }

    var dot: Dot
    /// The state now in a word (`Phase.title`), which the line, the dot's
    /// tooltip and VoiceOver say.
    var word: String
    var line: Line

    /// `download` is the model that rewords'.
    @MainActor
    init(phase: Phase, startStep: Supervisor.StartStep? = nil, resting: Bool, download: ModelDownload) {
        let stateLabel = phase.state == .preparing ? (startStep?.menuTitle ?? phase.title) : phase.title
        word = stateLabel
        dot = switch phase {
        case .running: .running
        case .paused, .ready: .stopped
        case .needsAttention: .attention
        case .preparing, .stopping: .changing
        }
        if case .needsAttention(let reason) = phase {
            line = .failure(reason, fix: Fix(for: reason, download: download))
        } else {
            line = .state(stateLabel, unloaded: phase == .running && resting, downloading: download.isUnderWay)
        }
    }

    var offersDownload: Bool {
        if case .failure(_, .download?) = line { return true }
        return false
    }
}

/// The header's view: "Cloak" at 13 points semibold with the
/// state's 6-point dot, over one line at 11 points, as the Mac's own
/// Battery and Wi-Fi menus have it, or over a failure, its fix beside it,
/// and its remedy. Its words start where the menu's items start theirs.
/// Never highlighted or chosen; its button closes the menu, as an item does.
final class MenuHeaderView: NSView {
    static let width: CGFloat = 310
    /// Where the menu's own items start their titles, measured from the
    /// menu's edge in docs/shots/menu-paused-dark.png.
    static let inset: CGFloat = 16.5

    var act: (Fix) -> Void = { _ in }
    private let dot = StateDot()
    private let line = NSTextField(labelWithString: "")
    private let problem = NSTextField(labelWithString: "")
    /// The whole of a failure cut short, as a tip (`Tip.swift`).
    private lazy var problemTip = TipArea(on: problem)
    private let fixButton = NSButton(title: "", target: nil, action: nil)
    private let remedy = NSTextField(wrappingLabelWithString: "")
    private let failure: NSStackView
    private var fix: Fix?

    init() {
        let title = NSTextField(labelWithString: "Cloak")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let name = NSStackView(views: [title, dot])
        // The dot sits on the title's baseline, its middle near half the
        // x-height (`StateDot`).
        name.alignment = .firstBaseline
        name.spacing = 6

        line.font = .systemFont(ofSize: 11)
        line.textColor = .secondaryLabelColor
        problem.font = .systemFont(ofSize: 11)
        problem.lineBreakMode = .byTruncatingTail
        problem.setContentHuggingPriority(.defaultLow, for: .horizontal)
        problem.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fixButton.controlSize = .small
        fixButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        fixButton.bezelStyle = .push
        fixButton.setContentHuggingPriority(.required, for: .horizontal)
        failure = NSStackView(views: [problem, fixButton])
        failure.alignment = .firstBaseline
        // The problem takes the room the button leaves.
        failure.distribution = .fill
        failure.spacing = 6
        remedy.font = .systemFont(ofSize: 11)
        remedy.textColor = .secondaryLabelColor
        remedy.preferredMaxLayoutWidth = Self.width - 2 * Self.inset

        let stack = NSStackView(views: [name, line, failure, remedy])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 40))
        fixButton.target = self
        fixButton.action = #selector(press)
        addSubview(stack)
        // Pinned on the leading side only, so a wider menu leaves its room
        // on the trailing side.
        // The failure's row is as wide as the header, so its button sits at
        // the trailing edge; the constraint is its own, so it stays while
        // the row is hidden.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.inset),
            failure.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.inset),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("not made from a file")
    }

    func show(_ header: MenuHeader) {
        dot.show(header.dot, word: header.word)
        switch header.line {
        case .state(let word, let unloaded, let downloading):
            line.stringValue = ([word] + (unloaded ? ["model unloaded"] : []) + (downloading ? ["downloading model"] : []))
                .joined(separator: ", ")
            line.isHidden = false
            failure.isHidden = true
            remedy.isHidden = true
        case .failure(let reason, let fix):
            problem.stringValue = reason.title(with: fix)
            problemTip.words = reason.title(with: fix)
            remedy.stringValue = reason.remedy(with: fix)
            self.fix = fix
            fixButton.title = fix?.title ?? ""
            fixButton.isHidden = fix == nil
            line.isHidden = true
            failure.isHidden = false
            remedy.isHidden = false
        }
        setFrameSize(NSSize(width: Self.width, height: fittingSize.height))
    }

    @objc private func press() {
        if let fix { act(fix) }
    }
}

/// The 6-point dot after the app's name: its colour is the state, and the
/// state's word is its tip (`Tip.swift`) and what VoiceOver reads for it. Its baseline
/// is half a point under it, so on the title's baseline its middle is near
/// half the title's x-height (an idea from the Llama app's menu, decision 14
/// in docs/plan.md).
private final class StateDot: NSView {
    private static let size: CGFloat = 6
    private var colour = NSColor.systemGray
    private lazy var tip = TipArea(on: self)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) {
        fatalError("not made from a file")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.size, height: Self.size)
    }

    override var firstBaselineOffsetFromTop: CGFloat {
        Self.size + 0.5
    }

    func show(_ dot: MenuHeader.Dot, word: String) {
        colour = switch dot {
        case .running: .systemGreen
        case .stopped: .systemYellow
        case .attention: .systemRed
        case .changing: .systemGray
        }
        tip.words = word
        setAccessibilityLabel(word)
        needsDisplay = true
    }

    // Drawn, not a layer's colour, so it follows a change to light or dark.
    override func draw(_ dirtyRect: NSRect) {
        colour.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// The menu bar icon: the 13-block Regents crown, block for block as the
/// design system's logos/regents-crown-flat-dark.svg draws it, with the state
/// in a 9-point badge over its lower trailing corner, cut clear of the crown
/// by a 1-point gap (an idea from the Llama app's icon, decision 14 in
/// docs/plan.md). The badge is play while Running, pause while Paused or
/// Ready, a dotted ring while starting, stop while stopping and an
/// exclamation mark when Cloak needs attention, so the state never rests on
/// colour alone. A template image, so the menu bar colours it as it does its
/// own icons; named for VoiceOver.
@MainActor
enum MenuBarIcon {
    /// Number of smooth rotation/pulse steps in the animated Darkbloom bloom.
    static let bloomFrameCount = 12

    static func image(
        _ phase: Phase,
        unread: Bool = false,
        darkbloomServing: Bool = false,
        bloomFrame: Int = 0,
        appearance: NSAppearance? = nil
    ) -> NSImage {
        // The master's blocks, 34 units square on a 36-unit pitch, at their
        // origins in its 252 by 186 view. At a ninth of a point per unit the
        // crown is 19.8 by 11.8 points and every origin lands on a whole
        // point, so on whole pixels at 1x and 2x.
        let blocks: [(x: CGFloat, y: CGFloat)] = [
            (31, 46), (103, 46), (175, 46),
            (31, 82), (67, 82), (103, 82), (139, 82), (175, 82),
            (31, 118), (67, 118), (103, 118), (139, 118), (175, 118),
        ]
        // Large, over about a third of the crown at its lower trailing
        // corner (18 November). Its edges are on whole points, so on
        // whole pixels at 1x and 2x.
        let badge = NSRect(x: 12, y: 6, width: 12, height: 12)
        // The glyph is knocked out of a filled disc; Starting's dotted ring
        // is the badge itself.
        let glyph: (name: String, size: CGFloat, knockedOut: Bool) =
            switch phase {
            case .running: ("play.fill", 8, true)
            case .paused, .ready: ("pause.fill", 8, true)
            case .preparing: ("circle.dotted", 12, false)
            case .stopping: ("stop.fill", 6, true)
            case .needsAttention: ("exclamationmark", 8, true)
            }
        let useColor = unread
        let drawAppearance = appearance ?? NSApp.effectiveAppearance
        let image = NSImage(size: NSSize(width: 26, height: 20), flipped: true) { _ in
            let render: () -> Bool = {
                guard let context = NSGraphicsContext.current else { return false }
                let foreground: NSColor = useColor ? .labelColor : .black
                foreground.setFill()
                foreground.setStroke()

                let crown = NSBezierPath()
                for block in blocks {
                    crown.appendRect(NSRect(x: (block.x - 31) / 9, y: (block.y - 46) / 9 + 0.5, width: 34 / 9, height: 34 / 9))
                }
                crown.fill()

                // Cut clear of the crown around the lower-trailing badge.
                context.compositingOperation = .destinationOut
                let cutoutInset: CGFloat = unread ? -1.8 : -1.0
                NSBezierPath(ovalIn: badge.insetBy(dx: cutoutInset, dy: cutoutInset)).fill()
                context.compositingOperation = .sourceOver

                if darkbloomServing {
                    // Animated 6-petal radiant Darkbloom bloom replacing the static play/pause icon.
                    Self.drawBloom(in: badge, frame: bloomFrame, color: foreground)
                } else {
                    if glyph.knockedOut {
                        foreground.setFill()
                        NSBezierPath(ovalIn: badge).fill()
                    }
                    // Every name is a system symbol.
                    let baseSymbol = NSImage(systemSymbolName: glyph.name, accessibilityDescription: nil)!
                        .withSymbolConfiguration(.init(pointSize: glyph.size, weight: .heavy))!
                    let symbol: NSImage
                    if !glyph.knockedOut && useColor {
                        symbol = baseSymbol.withSymbolConfiguration(.init(hierarchicalColor: foreground)) ?? baseSymbol
                    } else {
                        symbol = baseSymbol
                    }
                    let size = symbol.size
                    // On a whole point, so a pause's bars stay apart at 1x.
                    symbol.draw(
                        in: NSRect(
                            x: (badge.midX - size.width / 2).rounded(), y: (badge.midY - size.height / 2).rounded(),
                            width: size.width, height: size.height),
                        from: .zero, operation: glyph.knockedOut ? .destinationOut : .sourceOver, fraction: 1,
                        respectFlipped: true, hints: nil)
                }

                if unread {
                    // Vivid macOS blue ring around the badge when a chat reply has returned unread.
                    NSColor.systemBlue.setStroke()
                    let ring = NSBezierPath(ovalIn: badge.insetBy(dx: -0.75, dy: -0.75))
                    ring.lineWidth = 1.6
                    ring.stroke()
                }
                return true
            }
            if useColor {
                var ok = false
                drawAppearance.performAsCurrentDrawingAppearance { ok = render() }
                return ok
            }
            return render()
        }
        image.isTemplate = !useColor
        var parts = ["Cloak", phase.title]
        if darkbloomServing { parts.append("Serving Darkbloom") }
        if unread { parts.append("Unread reply") }
        image.accessibilityDescription = parts.joined(separator: ", ")
        return image
    }

    /// Draws a crisp 6-petal blooming rosette inside `badge` that gently
    /// rotates and breathes across `bloomFrameCount` frames while Darkbloom
    /// inference serving is active.
    private static func drawBloom(in badge: NSRect, frame: Int, color: NSColor) {
        let angleStep = (Double(frame % bloomFrameCount) / Double(bloomFrameCount)) * (.pi / 3.0)
        let pulse = 0.80 + 0.20 * sin((Double(frame % bloomFrameCount) / Double(bloomFrameCount)) * 2.0 * .pi)
        let center = CGPoint(x: badge.midX, y: badge.midY)
        let outerRadius = (badge.width * 0.48) * CGFloat(pulse)
        let innerRadius = badge.width * 0.17

        color.setStroke()
        color.setFill()
        for i in 0..<6 {
            let theta = angleStep + Double(i) * (.pi / 3.0)
            let p0 = CGPoint(
                x: center.x + CGFloat(cos(theta)) * innerRadius,
                y: center.y + CGFloat(sin(theta)) * innerRadius)
            let p1 = CGPoint(
                x: center.x + CGFloat(cos(theta)) * outerRadius,
                y: center.y + CGFloat(sin(theta)) * outerRadius)
            let petal = NSBezierPath()
            petal.move(to: p0)
            petal.line(to: p1)
            petal.lineWidth = 1.75
            petal.lineCapStyle = .round
            petal.stroke()
        }
        let coreRadius: CGFloat = 1.5
        NSBezierPath(ovalIn: NSRect(
            x: center.x - coreRadius, y: center.y - coreRadius,
            width: coreRadius * 2, height: coreRadius * 2)).fill()
    }
}

extension Phase {
    /// The state's symbol in Details and Chat: one shape per state, so the
    /// state never rests on colour alone, and a restart's own while its
    /// shutdown runs.
    var symbol: String {
        if self == .stopping(.restart) { return "arrow.clockwise.circle" }
        return switch state {
        case .paused: "pause.circle"
        case .preparing: "circle.dotted"
        case .running: "play.circle.fill"
        case .ready: "circle"
        case .stopping: "stop.circle"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }
}
