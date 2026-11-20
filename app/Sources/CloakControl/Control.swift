import Foundation

/// The control channel's messages: one request from `cloak`, one response
/// from the app, each a single line of JSON. A request carries a command
/// only, never task text (INS03).
public enum Command: String, Codable, Sendable, CaseIterable {
    case status
    case start
    case pause
    case resume
    case stop
    case verify
    case doctor
}

public struct Request: Codable, Sendable, Equatable {
    public var version = StatusDocument.currentVersion
    public var command: Command

    public init(_ command: Command) {
        self.command = command
    }
}

public struct Response: Codable, Sendable, Equatable {
    public var version = StatusDocument.currentVersion
    /// Why the command was not carried out; nil when it was.
    public var refusal: Refusal?
    /// The state once the command has settled.
    public var status: StatusDocument
    /// Present for `doctor` only.
    public var findings: [Finding]?

    public init(refusal: Refusal?, status: StatusDocument, findings: [Finding]? = nil) {
        self.refusal = refusal
        self.status = status
        self.findings = findings
    }
}

public enum Refusal: String, Codable, Sendable, CaseIterable {
    /// Another change is under way; try once it has settled.
    case busy
    /// Resume continues from Paused only.
    case notPaused = "not_paused"

    public var title: String {
        switch self {
        case .busy: "Cloak is busy. Try again in a moment."
        case .notPaused: "Cloak isn't paused."
        }
    }
}

/// One line of `cloak doctor`: a check and what it found. Redacted: no
/// keys, tokens or task text.
public struct Finding: Codable, Sendable, Equatable {
    public var name: String
    public var passed: Bool
    public var detail: String

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

/// The one JSON form of every message and of `--json` output.
public enum ControlCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
