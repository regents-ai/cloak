import Foundation
import os

/// The worker's log lines: numbers and fixed words, never request text.
public let log = Logger(subsystem: "sh.regents.cloak", category: "rewriter")

/// Exits the worker. The supervisor treats any exit as the loss of the worker
/// and fails the request in progress.
public func stop(_ reason: String) -> Never {
    log.error("stopping: \(reason, privacy: .public)")
    FileHandle.standardError.write(Data("\(ProcessInfo.processInfo.processName): \(reason)\n".utf8))
    exit(2)
}
