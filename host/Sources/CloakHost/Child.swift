import Foundation

/// A child process of this one whose exit can be awaited, and which, once
/// asked to stop, has `exitLimit` to exit before it is killed. The worker and
/// tor are each one.
final class Child: Sendable {
    /// How long a child asked to stop has to exit before it is killed.
    static let exitLimit: Duration = .seconds(10)

    let process: Process
    /// Ends once the process has exited.
    private let exit: Task<Void, Never>

    /// Starts `process`. `exited` runs once it has exited, before anything
    /// waiting for the exit goes on.
    init(_ process: Process, exited: @escaping @Sendable (Process) -> Void) throws {
        let (exits, ended) = AsyncStream.makeStream(of: Never.self)
        process.terminationHandler = { process in
            exited(process)
            ended.finish()
        }
        try process.run()
        self.process = process
        exit = Task { for await _ in exits {} }
    }

    /// How the process ended, once it has.
    func exited() async -> Termination {
        await exit.value
        return Termination(status: process.terminationStatus, signalled: process.terminationReason == .uncaughtSignal)
    }

    /// Waits for the process to exit once the caller has asked it to stop. If
    /// it has not exited within `exitLimit`, kills it, which it cannot refuse,
    /// and waits for that.
    func stopped(_ name: String) async {
        let exit = self.exit, process = self.process
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await exit.value }
            group.addTask {
                guard (try? await Task.sleep(for: Self.exitLimit)) != nil, process.isRunning else { return }
                log("\(name) did not exit within \(Self.exitLimit.components.seconds) seconds of being stopped; killed it")
                kill(process.processIdentifier, SIGKILL)
            }
            // The first to end: the exit, which cancels the limit, or the
            // limit, after which the exit follows the kill.
            await group.next()
            group.cancelAll()
        }
    }
}

/// How a child process ended: its exit status, or the signal that ended it.
public struct Termination: Sendable, Equatable, CustomStringConvertible {
    public let status: Int32
    public let signalled: Bool

    public var description: String { signalled ? "signal \(status)" : "exit status \(status)" }
}

/// Runs blocking work on a dispatch thread, so a task waiting for it holds no
/// thread of the task pool.
func onThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try work() }) }
    }
}
