import AppKit
import CloakControl
import CloakSupervisor
import Observation

/// The menu-bar item and its menu: the header (the app's name, the state's
/// dot and its line, or a failure with its fix), the way to the model's
/// download while its files are not all in place, Start or Pause, Chat,
/// Agents, Details, Settings, Check for Updates… (`Updates`),
/// Quit, and the release and build. Start, here or in the header, also
/// shows Chat. Every action
/// but Show in Finder is reachable from the keyboard, since the header's
/// other fixes are also Start or Details. It is AppKit's menu, since a
/// SwiftUI menu holds only plain items and the header is a view of its own.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let supervisor: Supervisor
    private let download: ModelDownload
    private let showChat: () -> Void
    private let showAgents: () -> Void
    private let showDetails: () -> Void
    private let showSettings: () -> Void
    private let checkForUpdates: () -> Void
    // As wide as its icon, which is wider than the bar is tall.
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let header = NSMenuItem()
    private let headerView = MenuHeaderView()
    private var open = false

    /// `model` is the model's folder, which Show in Finder reveals.
    init(
        supervisor: Supervisor, download: ModelDownload, model: URL, showChat: @escaping () -> Void,
        showAgents: @escaping () -> Void, showDetails: @escaping () -> Void,
        showSettings: @escaping () -> Void, checkForUpdates: @escaping () -> Void
    ) {
        self.supervisor = supervisor
        self.download = download
        self.showChat = showChat
        self.showAgents = showAgents
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
            // Reveals the folder; nothing in it is changed.
            case .showModel: NSWorkspace.shared.activateFileViewerSelecting([model])
            }
        }
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        item.button?.image = MenuBarIcon.image(supervisor.phase)
        // The menu lasts as long as the app, and so does this.
        Task {
            for await watched in Observations({
                Watched(phase: supervisor.phase, resting: supervisor.resting, download: download.state)
            }) {
                item.button?.image = MenuBarIcon.image(watched.phase)
                if open { rebuild() }
            }
        }
    }

    /// What the menu shows that can change while it is open.
    private struct Watched: Equatable {
        var phase: Phase
        var resting: Bool
        var download: ModelDownload.State
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
    }

    private func rebuild() {
        let phase = supervisor.phase
        let shown = MenuHeader(phase: phase, resting: supervisor.resting, downloading: download.isUnderWay)
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
            menu.addItem(Action("Start", symbol: "play.fill", key: "s") { [supervisor, showChat] in
                supervisor.send(.start)
                showChat()
            })
        }
        menu.addItem(Action("Chat", symbol: "bubble.left", run: showChat))
        menu.addItem(Action("Agents", symbol: "hammer", run: showAgents))
        #if DARKBLOOM
        menu.addItem(Action("Darkbloom", symbol: "server.rack") { AppDelegate.current.showDarkbloom() })
        #endif
        menu.addItem(Action("Details", symbol: "info.circle", key: "d", run: showDetails))
        menu.addItem(Action("Settings…", symbol: "gearshape", key: ",", run: showSettings))
        menu.addItem(.separator())
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

/// A menu item that runs its closure when chosen. Its symbol shows where the
/// Mac shows symbols in menus: macOS 26 does, and macOS 27 hides them, which
/// is left to the Mac (`preferredImageVisibility` stays automatic).
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
        run()
    }
}

/// What the menu's header says. Its dot is the state now, grey while Cloak
/// starts or stops, and its line says the state now, Starting or Stopping
/// meanwhile. A failure takes the line, with its remedy
/// and the one fix the menu can offer, once Cloak has stopped for it.
struct MenuHeader: Equatable {
    enum Dot: Equatable {
        case running, stopped, attention, changing
    }

    enum Fix: Equatable {
        case start
        case download(underWay: Bool)
        /// Reveal the model's folder in Finder.
        case showModel
    }

    enum Line: Equatable {
        /// The state's word, with what the model is doing beside it.
        case state(State, unloaded: Bool, downloading: Bool)
        case failure(Reason, fix: Fix?)
    }

    var dot: Dot
    /// The state now, which the line, the dot's tooltip and VoiceOver say.
    var state: State
    var line: Line

    init(phase: Phase, resting: Bool, downloading: Bool) {
        state = phase.state
        dot = switch phase {
        case .running: .running
        case .paused, .ready: .stopped
        case .needsAttention: .attention
        case .preparing, .stopping: .changing
        }
        if case .needsAttention(let reason) = phase {
            line = .failure(reason, fix: Self.fix(for: reason, downloading: downloading))
        } else {
            line = .state(phase.state, unloaded: phase == .running && resting, downloading: downloading)
        }
    }

    /// The fix the menu offers for a reason: the remedy's one step, or the
    /// way to it, when Cloak can offer one.
    static func fix(for reason: Reason, downloading: Bool) -> Fix? {
        switch reason {
        case .modelMissing: .download(underWay: downloading)
        case .modelChanged: .showModel
        case .torUnavailable, .torStopped, .workerUnavailable, .workerStopped, .guestFailed, .checkFailed: .start
        case .unsupportedHardware, .partMissing, .partChanged: nil
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

    var act: (MenuHeader.Fix) -> Void = { _ in }
    private let dot = StateDot()
    private let line = NSTextField(labelWithString: "")
    private let problem = NSTextField(labelWithString: "")
    private let fixButton = NSButton(title: "", target: nil, action: nil)
    private let remedy = NSTextField(wrappingLabelWithString: "")
    private let failure: NSStackView
    private var fix: MenuHeader.Fix?

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
        dot.show(header.dot, word: header.state.title)
        switch header.line {
        case .state(let state, let unloaded, let downloading):
            line.stringValue = ([state.title] + (unloaded ? ["model unloaded"] : []) + (downloading ? ["downloading model"] : []))
                .joined(separator: ", ")
            line.isHidden = false
            failure.isHidden = true
            remedy.isHidden = true
        case .failure(let reason, let fix):
            problem.stringValue = reason.title
            problem.toolTip = reason.title
            remedy.stringValue = reason.remedy
            self.fix = fix
            switch fix {
            case .start: fixButton.title = "Start Again"
            case .download(let underWay): fixButton.title = underWay ? "Downloading Model…" : "Download Model…"
            case .showModel: fixButton.title = "Show in Finder"
            case nil: break
            }
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
/// state's word is its tooltip and what VoiceOver reads for it. Its baseline
/// is half a point under it, so on the title's baseline its middle is near
/// half the title's x-height (an idea from the Llama app's menu, decision 14
/// in docs/plan.md).
private final class StateDot: NSView {
    private static let size: CGFloat = 6
    private var colour = NSColor.systemGray

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
        toolTip = word
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
enum MenuBarIcon {
    static func image(_ phase: Phase) -> NSImage {
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
        // corner (Sean, 18 November). Its edges are on whole points, so on
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
        let image = NSImage(size: NSSize(width: 25, height: 19), flipped: true) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            let crown = NSBezierPath()
            for block in blocks {
                crown.appendRect(NSRect(x: (block.x - 31) / 9, y: (block.y - 46) / 9, width: 34 / 9, height: 34 / 9))
            }
            crown.fill()
            context.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: badge.insetBy(dx: -1, dy: -1)).fill()
            context.compositingOperation = .sourceOver
            if glyph.knockedOut { NSBezierPath(ovalIn: badge).fill() }
            // Every name is a system symbol.
            let symbol = NSImage(systemSymbolName: glyph.name, accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: glyph.size, weight: .heavy))!
            let size = symbol.size
            // On a whole point, so a pause's bars stay apart at 1x.
            symbol.draw(
                in: NSRect(
                    x: (badge.midX - size.width / 2).rounded(), y: (badge.midY - size.height / 2).rounded(), width: size.width,
                    height: size.height),
                from: .zero, operation: glyph.knockedOut ? .destinationOut : .sourceOver, fraction: 1, respectFlipped: true,
                hints: nil)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Cloak, \(phase.state.title)"
        return image
    }
}

extension Phase {
    /// The state's symbol in Details and Chat: one shape per state, so the
    /// state never rests on colour alone.
    var symbol: String {
        switch state {
        case .paused: "pause.circle"
        case .preparing: "circle.dotted"
        case .running: "play.circle.fill"
        case .ready: "circle"
        case .stopping: "stop.circle"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }
}
