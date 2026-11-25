import AppKit
import SwiftUI

/// Non-transient macOS hover popover (`NSPopover.Behavior.applicationDefined`)
/// for interactive controls like `AgentPill`.
///
/// Unlike SwiftUI's built-in `.popover`, which uses `.transient` and swallows
/// the first mouse click outside the popover (preventing a click on the trigger
/// button itself from firing and dismissing the popover), `.applicationDefined`
/// lets clicks on the underlying button pass through immediately without
/// closing or disturbing the tooltip.
private struct HoverPopoverModifier<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let popoverContent: () -> PopoverContent

    func body(content: Content) -> some View {
        content.background(
            HoverPopoverAnchor(
                isPresented: $isPresented,
                arrowEdge: arrowEdge,
                content: popoverContent
            )
            .allowsHitTesting(false)
        )
    }
}

extension View {
    func hoverPopover<Content: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge = .top,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(HoverPopoverModifier(isPresented: isPresented, arrowEdge: arrowEdge, popoverContent: content))
    }
}

private struct HoverPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onDetach = { [weak coordinator = context.coordinator] in
            coordinator?.close(syncBinding: true)
        }
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.isPresented = $isPresented
        context.coordinator.update(
            shown: isPresented,
            anchor: nsView,
            arrowEdge: arrowEdge,
            content: AnyView(content())
        )
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: Coordinator) {
        nsView.onDetach = nil
        coordinator.teardown()
    }

    final class AnchorView: NSView {
        var onDetach: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                onDetach?()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var isPresented: Binding<Bool>
        private var popover: NSPopover?
        private var hostingController: NSHostingController<AnyView>?
        private var resignObserver: NSObjectProtocol?

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
            super.init()
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.close(syncBinding: true)
                }
            }
        }

        func update(shown: Bool, anchor: NSView, arrowEdge: Edge, content: AnyView) {
            if shown {
                guard anchor.window != nil, NSApp.isActive else { return }
                let host: NSHostingController<AnyView>
                if let existing = hostingController {
                    existing.rootView = content
                    host = existing
                } else {
                    host = NSHostingController(rootView: content)
                    host.sizingOptions = [.preferredContentSize]
                    hostingController = host
                }

                let pop: NSPopover
                if let existing = popover {
                    pop = existing
                } else {
                    pop = NSPopover()
                    pop.behavior = .applicationDefined
                    pop.animates = true
                    pop.contentViewController = host
                    pop.delegate = self
                    popover = pop
                }

                if !pop.isShown {
                    let edge: NSRectEdge =
                        switch arrowEdge {
                        case .top: anchor.isFlipped ? .minY : .maxY
                        case .bottom: anchor.isFlipped ? .maxY : .minY
                        case .leading: .minX
                        case .trailing: .maxX
                        }
                    pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
                }
            } else {
                close(syncBinding: false)
            }
        }

        func close(syncBinding: Bool) {
            if let popover, popover.isShown {
                popover.performClose(nil)
            }
            if syncBinding {
                let binding = isPresented
                Task { @MainActor in
                    if binding.wrappedValue {
                        binding.wrappedValue = false
                    }
                }
            }
        }

        func teardown() {
            close(syncBinding: false)
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
                self.resignObserver = nil
            }
            popover?.delegate = nil
            popover = nil
            hostingController = nil
        }

        nonisolated func popoverDidClose(_ notification: Notification) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isPresented.wrappedValue {
                    self.isPresented.wrappedValue = false
                }
            }
        }
    }
}
