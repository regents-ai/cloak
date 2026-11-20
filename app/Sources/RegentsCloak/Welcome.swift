import AppKit
import SwiftUI

/// The welcome, once: on the app's first launch, by a flag in its defaults
/// set as it shows. The Regents crown, the app's icon, with what Cloak does
/// as its help, and where Cloak is, under the Development mark that says
/// one wallet pays for every chat. It says what Cloak does, never what that
/// guarantees, and it starts nothing.
struct WelcomeView: View {
    static let key = "welcomed"

    let close: () -> Void

    static func window() -> NSWindow {
        let window = ClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome"
        window.contentViewController = NSHostingController(rootView: WelcomeView { [weak window] in window?.close() })
        return window
    }

    var body: some View {
        VStack(spacing: 0) {
            DevelopmentBar()
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .help("Cloak rewords each message on this Mac, then sends it through Tor.")
                    .accessibilityLabel("Cloak rewords each message on this Mac, then sends it through Tor.")
                Text("Cloak lives in the menu bar and stays paused until you press Start.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
