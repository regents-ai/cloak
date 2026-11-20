import ArgumentParser
import CloakControl
import Foundation

/// `cloak`: the terminal interface to the same supervisor the menu-bar app
/// runs, over its control channel. It takes no task text (INS03), and prints
/// no prompt text, keys or secrets.
@main
struct Cloak: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cloak",
        abstract: "Control Cloak.",
        subcommands: [StatusCommand.self, Start.self, Pause.self, Resume.self, Stop.self, Verify.self, Doctor.self])
}

struct Output: ParsableArguments {
    @Flag(help: "Print versioned JSON.")
    var json = false
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the state and what to do next.")
    @OptionGroup var output: Output
    func run() throws { try perform(.status, output) }
}

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start, opening Cloak if it isn't open, and wait until it runs.")
    @OptionGroup var output: Output
    func run() throws { try perform(.start, output) }
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop everything and stay paused until started again.")
    @OptionGroup var output: Output
    func run() throws { try perform(.pause, output) }
}

struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start again from paused, checking everything first.")
    @OptionGroup var output: Output
    func run() throws { try perform(.resume, output) }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop everything and be ready to start again.")
    @OptionGroup var output: Output
    func run() throws { try perform(.stop, output) }
}

struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the startup check, then stop again.")
    @OptionGroup var output: Output
    func run() throws { try perform(.verify, output) }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check this Mac and every installed part.")
    @OptionGroup var output: Output
    func run() throws { try perform(.doctor, output) }
}

/// Sends `command` and prints the answer. Exits 1 when the command was
/// refused, the app cannot be reached, or the supervisor needs attention.
func perform(_ command: Command, _ output: Output) throws {
    let response: Response
    do throws(ControlError) {
        do throws(ControlError) {
            response = try ControlClient.send(Request(command))
        } catch .notRunning where command == .start {
            try AppLauncher.open()
            response = try ControlClient.send(Request(command))
        }
    } catch {
        print(output.json ? Rendering.json(ErrorDocument(error)) : Rendering.human(error))
        throw ExitCode.failure
    }
    print(output.json ? Rendering.json(response) : Rendering.human(response))
    if response.refusal != nil || response.status.state == .needsAttention {
        throw ExitCode.failure
    }
}

/// What `--json` prints when there is no answer from the app.
struct ErrorDocument: Encodable {
    var version = StatusDocument.currentVersion
    var error: String
    var nextAction: NextAction

    init(_ error: ControlError) {
        switch error {
        case .notRunning: (self.error, nextAction) = ("not_running", .start)
        case .refused: (self.error, nextAction) = ("refused", .none)
        case .failed: (self.error, nextAction) = ("failed", .none)
        }
    }
}

enum Rendering {
    static func json(_ value: some Encodable) -> String {
        String(decoding: try! ControlCoding.encoder().encode(value), as: UTF8.self)
    }

    static func human(_ response: Response) -> String {
        let status = response.status
        var lines = [String]()
        if let refusal = response.refusal { lines.append(refusal.title) }
        lines.append(status.state.title)
        if let reason = status.reason {
            lines.append(reason.title)
            lines.append(reason.remedy)
        }
        lines.append("Model: \(status.model.name) (\(status.model.label))")
        lines.append("Release: \(status.release) (\(status.build))")
        if let check = status.check {
            lines.append("Last check: \(check.passed ? "passed" : "failed") at \(check.at.formatted(date: .omitted, time: .standard))")
        }
        for finding in response.findings ?? [] {
            lines.append("\(finding.passed ? "ok    " : "failed") \(finding.name): \(finding.detail)")
        }
        return lines.joined(separator: "\n")
    }

    static func human(_ error: ControlError) -> String {
        error == .notRunning ? "\(error.description)\nRun cloak start to open it." : error.description
    }
}

/// Opens the app this `cloak` is part of, and waits until it answers.
enum AppLauncher {
    static let limit = 30

    static func open() throws(ControlError) {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { throw .notRunning }
        let before = socketIdentity()
        do {
            try Places.makeOwnerOnly(Places.control)
        } catch {
            throw .failed("cannot make \(Places.control.path): \(error)")
        }
        // The app publishes its socket by renaming it into the control
        // folder, which changes the folder; any socket left from an earlier
        // run is replaced, so a new one is a socket file that was not there.
        let folder = Darwin.open(Places.control.path, O_EVTONLY)
        guard folder >= 0 else { throw .failed("cannot watch \(Places.control.path): \(String(cString: strerror(errno)))") }
        let published = DispatchSemaphore(value: 0)
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: .write, queue: .global())
        watch.setEventHandler {
            if let now = socketIdentity(), now != before { published.signal() }
        }
        watch.setCancelHandler { close(folder) }
        watch.resume()
        defer { watch.cancel() }
        let opener = Process()
        opener.executableURL = URL(filePath: "/usr/bin/open")
        opener.arguments = ["-g", bundle.path]
        do {
            try opener.run()
        } catch {
            throw .failed("cannot open \(bundle.path): \(error)")
        }
        opener.waitUntilExit()
        guard published.wait(timeout: .now() + .seconds(limit)) == .success else {
            throw .failed("Cloak did not open within \(limit) seconds")
        }
    }

    /// The socket file's inode, or nil when there is none.
    private static func socketIdentity() -> ino_t? {
        var info = stat()
        guard stat(Places.socket.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return info.st_ino
    }
}
