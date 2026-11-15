import CloakHost
import Foundation
import os

/// The owner's agent tasks under way in one run, each on its own connection
/// to the guest's runner, so that the shutdown can end each with
/// `Runner.Stop.stopped` before it stops the guest.
@MainActor
final class AgentTasks {
    private typealias Events = AsyncThrowingStream<Runner.Event, any Error>

    private var running: [UUID: (pump: Task<Void, Never>, events: Events.Continuation)] = [:]
    private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "supervisor")

    nonisolated init() {}

    /// Runs `request` on a connection from `connect`: the runner's events
    /// as they come. Ending the stream first cancels the pump, which closes
    /// the connection.
    func run(
        _ request: Runner.Request, connect: @escaping @MainActor () async throws -> Int32
    ) -> AsyncThrowingStream<Runner.Event, any Error> {
        let (events, continuation) = Events.makeStream()
        let id = UUID()
        let started = ContinuousClock.now
        let pump = Task {
            // The runner's events end with the exit or a stop; without
            // either, the task was cancelled.
            var end = "cancelled"
            do {
                let socket = try await connect()
                for try await event in Runner.run(socket, request) {
                    if case .exited(let termination) = event { end = "\(termination)" }
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                end = "\(error)"
                continuation.finish(throwing: error)
            }
            running[id] = nil
            logger.info("agent task ended (\(end, privacy: .public)) after \(started.duration(to: .now), privacy: .public)")
        }
        running[id] = (pump, continuation)
        continuation.onTermination = { _ in pump.cancel() }
        return events
    }

    /// Ends every task under way with `Runner.Stop.stopped`, and closes its
    /// connection.
    func stop() {
        for (pump, events) in running.values {
            events.finish(throwing: Runner.Stop.stopped)
            pump.cancel()
        }
        running = [:]
    }

    /// A task that cannot run: its events end at once with `stop`.
    static func refused(_ stop: Runner.Stop) -> AsyncThrowingStream<Runner.Event, any Error> {
        let (events, continuation) = Events.makeStream()
        continuation.finish(throwing: stop)
        return events
    }
}
