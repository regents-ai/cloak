import AppKit
import CloakControl

// The app's AppleScript commands, as RegentsCloak.sdef names them: start,
// pause, and show each window. None takes text or changes a setting, and
// none sends, spends or touches the wallet. A start or pause that doesn't
// apply now fails with the reason the menu's would give. Cocoa runs each on
// the main thread.

@objc(CloakStartCommand)
final class StartCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        refuse(MainActor.assumeIsolated { AppDelegate.current.supervisor.send(.start) })
        return nil
    }
}

@objc(CloakPauseCommand)
final class PauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        refuse(MainActor.assumeIsolated { AppDelegate.current.supervisor.send(.pause) })
        return nil
    }
}

@objc(CloakShowChatCommand)
final class ShowChatCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { AppDelegate.current.showChat() }
        return nil
    }
}

@objc(CloakShowAgentsCommand)
final class ShowAgentsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { AppDelegate.current.showAgents() }
        return nil
    }
}

@objc(CloakShowDetailsCommand)
final class ShowDetailsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { AppDelegate.current.showDetails() }
        return nil
    }
}

@objc(CloakShowSettingsCommand)
final class ShowSettingsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { AppDelegate.current.showSettings() }
        return nil
    }
}

extension NSScriptCommand {
    /// Fails the command with the refusal's words, when there is one.
    fileprivate func refuse(_ refusal: Refusal?) {
        guard let refusal else { return }
        scriptErrorNumber = errAEEventFailed
        scriptErrorString = refusal.title
    }
}
