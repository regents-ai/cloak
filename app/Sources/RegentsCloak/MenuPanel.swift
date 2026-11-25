import AppKit
import CloakControl
import CloakSupervisor
import Observation
import SwiftUI

/// Native macOS 27 menu bar panel anchored below Cloak's `NSStatusItem` via
/// `NSStatusItemExpandedInterfaceDelegate` + `NSStatusItemExpandedInterfaceSession`.
///
/// Unifies status, live 5-step startup progress, inline Quick Prompt, Cover
/// Traffic toggle, mode switcher, and key actions inside a single Liquid Glass
/// surface that works from the keyboard and closes when focus moves away.
@MainActor
final class MenuPanelController: NSObject {
    struct Actions {
        let showChat: () -> Void
        let showFunds: () -> Void
        let showTour: () -> Void
        let showDetails: () -> Void
        let showSettings: () -> Void
        let checkForUpdates: () -> Void
        let submitPrompt: (String) -> Void
        let selectMode: (Chat.Kind) -> Void
        let activeMode: () -> Chat.Kind
        #if DARKBLOOM
        let showDarkbloom: () -> Void
        #endif
    }

    @MainActor
    @Observable
    fileprivate final class PanelState {
        var selectedMode: Chat.Kind = .llama
    }

    private let supervisor: Supervisor
    private let download: ModelDownload
    private let settings: AppSettings
    private let actions: Actions
    private let state = PanelState()
    private let panel: MenuBarPanel
    private let hosting: NSHostingController<MenuPanelView>
    private var cancelSession: (() -> Void)?
    private weak var anchorButtonWindow: NSWindow?
    private var globalClickMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var resizeTask: Task<Void, Never>?
    private var isShowing = false

    init(
        supervisor: Supervisor,
        download: ModelDownload,
        settings: AppSettings,
        actions: Actions
    ) {
        self.supervisor = supervisor
        self.download = download
        self.settings = settings
        self.actions = actions
        self.panel = MenuBarPanel()
        self.hosting = NSHostingController(
            rootView: MenuPanelView(
                supervisor: supervisor,
                download: download,
                settings: settings,
                state: state,
                actions: actions,
                dismiss: {}
            )
        )
        super.init()

        hosting.rootView = MenuPanelView(
            supervisor: supervisor,
            download: download,
            settings: settings,
            state: state,
            actions: actions,
            dismiss: { [weak self] in self?.requestDismiss() }
        )
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 18
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.contentView = hosting.view
        panel.contentView = glass
        panel.onResignKey = { [weak self] in
            self?.requestDismiss()
        }
        panel.onEscape = { [weak self] in
            self?.requestDismiss()
        }
    }

    func show(below statusItem: NSStatusItem, cancelSession: @escaping () -> Void) {
        download.refresh()
        state.selectedMode = actions.activeMode()
        anchorButtonWindow = statusItem.button?.window
        self.cancelSession = cancelSession
        isShowing = true

        let size = measuredSize()
        panel.setContentSize(size)
        position(below: statusItem, size: size)
        installMonitors()
        startResizeObserver()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide(animated: Bool) {
        guard isShowing || panel.isVisible else { return }
        isShowing = false
        cancelSession = nil
        anchorButtonWindow = nil
        resizeTask?.cancel()
        resizeTask = nil
        removeMonitors()
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.panel.orderOut(nil)
                    self?.panel.alphaValue = 1
                }
            }
        } else {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    private func measuredSize() -> NSSize {
        let width: CGFloat = 336
        let fitting = hosting.sizeThatFits(in: CGSize(width: width, height: 640))
        return NSSize(width: width, height: min(max(fitting.height, 260), 620))
    }

    /// Keeps the panel's top edge pinned under the menu bar when startup steps
    /// or failure banners expand/collapse while the panel is already open.
    private func startResizeObserver() {
        resizeTask?.cancel()
        resizeTask = Task { [weak self, supervisor, download] in
            for await _ in Observations({ (supervisor.phase, supervisor.startStep, download.state) }) {
                guard let self, self.isShowing else { break }
                await Task.yield()
                guard self.isShowing else { break }
                self.updateHeightPinnedToTop()
            }
        }
    }

    private func updateHeightPinnedToTop() {
        let next = measuredSize()
        let current = panel.frame
        guard abs(current.height - next.height) > 1 else { return }
        let top = current.maxY
        let frame = NSRect(x: current.minX, y: top - next.height, width: next.width, height: next.height)
        panel.setFrame(frame, display: true, animate: true)
    }

    private func requestDismiss() {
        guard isShowing else { return }
        if let cancel = cancelSession {
            cancelSession = nil
            cancel()
        } else {
            hide(animated: true)
        }
    }

    private func position(below statusItem: NSStatusItem, size: NSSize) {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            panel.center()
            return
        }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let idealX = buttonFrame.midX - size.width / 2
        let clampedX = min(max(idealX, visible.minX + 8), visible.maxX - size.width - 8)
        let y = buttonFrame.minY - size.height - 6
        panel.setFrameOrigin(NSPoint(x: clampedX, y: max(visible.minY + 8, y)))
    }

    private func installMonitors() {
        removeMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.requestDismiss()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isShowing else { return event }
            if event.window !== self.panel && event.window !== self.anchorButtonWindow {
                self.requestDismiss()
            }
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            if event.keyCode == 53 { // Escape
                self.requestDismiss()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
                switch key {
                case ",":
                    self.requestDismiss()
                    self.actions.showSettings()
                    return nil
                case "q":
                    self.requestDismiss()
                    NSApp.terminate(nil)
                    return nil
                case "o":
                    self.requestDismiss()
                    self.actions.showChat()
                    return nil
                default:
                    break
                }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }
}

private final class MenuBarPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onEscape: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 336, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        // NSGlassEffectView provides its own native Liquid Glass rim and elevation;
        // enabling NSWindow.hasShadow on a borderless glass panel causes WindowServer
        // to draw rectangular dark shadow artifacts outside the 18pt rounded corners.
        hasShadow = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// Routes standard Edit shortcuts (`⌘C`, `⌘V`, `⌘X`, `⌘A`, `⌘Z`, `⇧⌘Z`)
    /// directly to the responder chain so text editing works cleanly even when
    /// Cloak is running in `.accessory` (menu-bar-only) mode with no main menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if flags == .command {
            switch key {
            case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
            case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
            default: break
            }
        } else if flags == [.command, .shift], key == "z" {
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct MenuPanelView: View {
    let supervisor: Supervisor
    let download: ModelDownload
    @Bindable var settings: AppSettings
    let state: MenuPanelController.PanelState
    let actions: MenuPanelController.Actions
    let dismiss: () -> Void

    @State private var draft = ""
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var surfaceFill: Color {
        reduceTransparency ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(0.06)
    }

    private var surfaceStroke: Color {
        contrast == .increased ? Color(nsColor: .labelColor).opacity(0.35) : Color.primary.opacity(0.10)
    }

    private var cardShape: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true)
    }

    private var statusColor: Color {
        switch supervisor.phase {
        case .running: .green
        case .paused, .ready: .yellow
        case .needsAttention: .red
        case .preparing, .stopping: .secondary
        }
    }

    private var statusSubtitle: String {
        if supervisor.phase.state == .preparing {
            return supervisor.startStep?.menuTitle ?? supervisor.phase.title
        }
        if supervisor.phase == .running, supervisor.resting {
            return "Running · rewriter resting"
        }
        return supervisor.phase.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            if supervisor.phase.state == .preparing {
                VStack(alignment: .leading, spacing: 8) {
                    StartupProgressView(supervisor: supervisor)
                }
                .padding(10)
                .background(surfaceFill, in: cardShape)
                .overlay(cardShape.stroke(surfaceStroke, lineWidth: 1))
            } else if case .needsAttention(let reason) = supervisor.phase {
                attentionBanner(reason: reason)
            }

            if download.state != .installed {
                Button {
                    dismiss()
                    actions.showDetails()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        Text(download.isUnderWay ? "Downloading local rewriter…" : "Download local rewriter model…")
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(surfaceFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(surfaceStroke, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .hover(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            quickPromptField
            if state.selectedMode != .llama {
                privacyToggleStrip
            }
            controlsSection
            actionsGrid
            Divider().opacity(0.5)
            footerRow
        }
        .padding(14)
        .frame(width: 336)
        .background(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .textSelection(.enabled)
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Cloak")
                        .font(.headline)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                }
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            switch supervisor.phase {
            case .preparing, .running:
                Button {
                    supervisor.send(.pause)
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            case .stopping:
                ProgressView()
                    .controlSize(.small)
            case .paused, .ready, .needsAttention:
                let disabled: Bool = {
                    if download.state != .installed { return true }
                    if case .needsAttention(let reason) = supervisor.phase {
                        return Fix.startStops(for: reason, download: download)
                    }
                    return false
                }()
                Button {
                    supervisor.send(.start)
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(disabled)
            }
        }
    }

    private func attentionBanner(reason: Reason) -> some View {
        let fix = Fix(for: reason, download: download)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Text(reason.title(with: fix))
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            Text(reason.remedy(with: fix))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let fix {
                HStack {
                    Spacer()
                    Button(fix.title) {
                        dismiss()
                        switch fix {
                        case .start:
                            supervisor.send(.start)
                            actions.showChat()
                        case .download:
                            actions.showDetails()
                        case .repair:
                            download.repair()
                            actions.showDetails()
                        case .showModel:
                            Fix.showModel()
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(reduceTransparency ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
    }

    private var quickPromptField: some View {
        QuickDraftField(
            draft: $draft,
            fill: surfaceFill,
            stroke: surfaceStroke,
            shape: cardShape,
            submit: submitDraft
        )
    }

    private func submitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        dismiss()
        actions.submitPrompt(trimmed)
    }

    /// Compact icon toggle strip directly below the draft input — only shows
    /// switches that are genuinely toggleable for the active mode:
    /// - NEAR: Tor (Direct vs. Tor), plus Cover Traffic when Tor is on.
    /// - Token Inference & Anon V: Cover Traffic only (Tor is always required).
    /// - Local: hidden (100% offline).
    private var privacyToggleStrip: some View {
        HStack(spacing: 6) {
            if state.selectedMode == .near {
                CompactPrivacyToggleButton(
                    symbol: torSymbol,
                    label: "Tor",
                    isOn: settings.nearTor,
                    isActive: settings.nearTor && supervisor.phase == .running,
                    isBusy: settings.nearTor && supervisor.phase.state == .preparing,
                    tip: settings.nearTor
                        ? (supervisor.phase == .running
                            ? "Tor is ON for NEAR — click to switch NEAR to direct (faster, exposes your IP)."
                            : "Tor is enabled for NEAR (starting Cloak…) — click to switch NEAR to direct.")
                        : "Tor is OFF for NEAR (direct connection) — click to route NEAR through Tor."
                ) {
                    let next = !settings.nearTor
                    settings.nearTor = next
                    if next, supervisor.phase != .running, supervisor.phase.state != .preparing, download.state == .installed {
                        supervisor.send(.start)
                    }
                }
            }
            if state.selectedMode == .token || state.selectedMode == .v || (state.selectedMode == .near && settings.nearTor) {
                CompactPrivacyToggleButton(
                    symbol: "waveform.path",
                    label: "Cover Traffic",
                    isOn: settings.cover,
                    isActive: settings.cover && supervisor.phase == .running,
                    isBusy: false,
                    tip: settings.cover
                        ? "Cover Traffic is ON (\(coverStatusText)) — click to turn off."
                        : "Cover Traffic is OFF — click to send random public Tor fetches (~3/min) to blur prompt timing."
                ) {
                    settings.cover.toggle()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var controlsSection: some View {
        HStack(spacing: 3) {
            ForEach([Chat.Kind.llama, .near, .token, .v], id: \.self) { kind in
                ModePillButton(
                    title: shortModeName(kind),
                    symbol: kind.symbol,
                    active: state.selectedMode == kind
                ) {
                    state.selectedMode = kind
                    actions.selectMode(kind)
                }
            }
        }
        .padding(3)
        .background(surfaceFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(surfaceStroke, lineWidth: 1))
    }

    private var coverStatusText: String {
        guard settings.cover else { return "Off" }
        guard supervisor.phase == .running else { return "Enabled · starts when Cloak runs" }
        let recent = supervisor.coverLog.countInLastHour()
        if recent > 0 {
            return "Active · \(recent) Tor \(recent == 1 ? "fetch" : "fetches") in last hr"
        }
        return "Active · ~3 public Tor fetches/min"
    }

    private func shortModeName(_ kind: Chat.Kind) -> String {
        switch kind {
        case .llama: "Local"
        case .near: "NEAR"
        case .token: "Token"
        case .v: "zkAPI"
        }
    }

    private var actionsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            PanelTileButton(title: "Chat", symbol: "bubble.left", fill: surfaceFill, stroke: surfaceStroke) {
                dismiss()
                actions.showChat()
            }
            PanelTileButton(title: "Funds", symbol: "creditcard", fill: surfaceFill, stroke: surfaceStroke) {
                dismiss()
                actions.showFunds()
            }
            PanelTileButton(title: "Settings", symbol: "gearshape", fill: surfaceFill, stroke: surfaceStroke) {
                dismiss()
                actions.showSettings()
            }
            #if DARKBLOOM
            PanelTileButton(title: "Serving", symbol: "server.rack", fill: surfaceFill, stroke: surfaceStroke) {
                dismiss()
                actions.showDarkbloom()
            }
            #else
            PanelTileButton(title: "Tour", symbol: "sparkles", fill: surfaceFill, stroke: surfaceStroke) {
                dismiss()
                actions.showTour()
            }
            #endif
        }
    }

    private var footerRow: some View {
        HStack(spacing: 10) {
            #if DARKBLOOM
            FooterLinkButton(title: "Tour") {
                dismiss()
                actions.showTour()
            }
            #endif
            FooterLinkButton(title: "Updates") {
                dismiss()
                actions.checkForUpdates()
            }
            FooterLinkButton(title: "Quit") {
                dismiss()
                NSApp.terminate(nil)
            }
            Spacer()
            Text("\(supervisor.manifest.release)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 2)
    }
}

private struct QuickDraftField: View {
    @Binding var draft: String
    let fill: Color
    let stroke: Color
    let shape: ConcentricRectangle
    let submit: () -> Void

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            ZStack(alignment: .leading) {
                if draft.isEmpty {
                    Text("New private draft…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .onSubmit(submit)
            }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)

            ZStack {
                if hasDraft {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Draft in Chat")
                } else {
                    Text("↵")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22, height: 22)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(fill, in: shape)
        .overlay(shape.stroke(stroke, lineWidth: 1))
    }
}

private struct ModePillButton: View {
    let title: String
    let symbol: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    private let pillShape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2)
                Text(title)
                    .font(.caption.weight(active ? .semibold : .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 26)
            .padding(.horizontal, 6)
            .background(
                active
                    ? Color.accentColor
                    : (hovering ? Color.primary.opacity(0.08) : Color.clear),
                in: pillShape
            )
            .foregroundStyle(active ? Color.white : (hovering ? Color.primary : Color.secondary))
            .contentShape(pillShape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PanelTileButton: View {
    let title: String
    let symbol: String
    let fill: Color
    let stroke: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                hovering ? Color.primary.opacity(0.10) : fill,
                in: ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true)
            )
            .overlay(ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true).stroke(stroke, lineWidth: 1))
            .contentShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Compact circular/pill icon button for genuinely toggleable privacy features
/// (Tor in NEAR mode, Cover Traffic in Tor-backed modes). Turns green when on.
struct CompactPrivacyToggleButton: View {
    let symbol: String
    let label: String
    let isOn: Bool
    let isActive: Bool
    let isBusy: Bool
    let tip: String
    let action: () -> Void
    @State private var hovering = false

    private var iconColor: Color {
        if isActive { return .green }
        if isOn { return .green.opacity(0.8) }
        return hovering ? .primary : .secondary
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: 26, height: 26)
            .background(
                isOn
                    ? Color.green.opacity(hovering ? 0.22 : 0.14)
                    : (hovering ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05)),
                in: Circle()
            )
            .overlay(
                Circle()
                    .strokeBorder(
                        isOn ? Color.green.opacity(0.45) : Color.primary.opacity(0.12),
                        lineWidth: 1
                    )
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tip(tip)
        .accessibilityLabel("\(label): \(isOn ? "on" : "off")")
    }
}

private struct FooterLinkButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    hovering ? Color.primary.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
