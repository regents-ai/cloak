import AppKit
import CloakControl
import CloakSupervisor
import SwiftUI

/// The menu: the state, why it needs attention, Start or Pause, Chat, Agents,
/// Details and Quit. Each item is reachable from the keyboard.
struct MenuContent: View {
    let supervisor: Supervisor
    let showChat: () -> Void
    let showAgents: () -> Void
    let showDetails: () -> Void

    var body: some View {
        let phase = supervisor.phase
        Text(phase.state.title)
        if let reason = phase.reason {
            Text(reason.title)
        }
        Divider()
        switch phase {
        case .preparing, .running:
            Button("Pause") { supervisor.send(.pause) }
                .keyboardShortcut("p")
        case .stopping:
            Button("Start") {}
                .disabled(true)
        case .paused, .ready, .needsAttention:
            Button("Start") { supervisor.send(.start) }
                .keyboardShortcut("s")
        }
        Button("Chat…", action: showChat)
        Button("Agents…", action: showAgents)
        Button("Details…", action: showDetails)
            .keyboardShortcut("d")
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The menu bar icon: one shape per state, so the state never rests on
/// colour alone, named for VoiceOver.
struct MenuLabel: View {
    let phase: Phase

    var body: some View {
        Image(systemName: phase.symbol)
            .accessibilityLabel("Regents Cloak, \(phase.state.title)")
    }
}

extension Phase {
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
