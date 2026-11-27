import Foundation

/// Exports selected NEAR AI Gateway chats as Letta Trajectory v1 JSON files
/// into an owner-only local folder (excluded from Time Machine and Spotlight)
/// so the user can hand them to the NEAR AI Gateway app under Exported Traces.
///
/// Safety invariants:
/// - Only conversations marked `conversation.isNear` (never Local, Token
///   Inference, Anon V, or Agent) are accepted.
/// - Only answered turns are exported, using `turn.sent` (never an
///   un-rewritten `original`, no keys, no hardware proofs, no local paths).
/// - Cloak sends nothing over the network; NEAR AI Gateway handles redaction,
///   before-and-after review, consent, and upload.
public enum NearTraceExporter {
    public enum Failure: Error, Equatable, Sendable {
        /// The conversation is not a NEAR AI Gateway chat (or is an Agent task).
        case notNearChat
        /// The conversation has no answered turns yet.
        case noAnsweredTurns
        /// Disk creation or write failed.
        case io(String)
    }

    /// Summary of an already-exported trace file on disk.
    public struct ExportedFile: Sendable, Equatable {
        public let conversationID: UUID
        public let url: URL
        public let bytes: Int
        public let modifiedAt: Date
        /// Number of answered user/assistant turn pairs recorded in the file.
        public let turnCount: Int
    }

    /// Turns eligible for TraceCommons Letta Trajectory v1 export:
    /// TraceCommons (`trajectory.rs`) fails closed with `malformed_record` on
    /// any assistant record with empty `content`, so turns with blank prompts
    /// or blank answers are excluded cleanly.
    public static func eligibleTurns(in conversation: Conversation) -> [Turn] {
        guard conversation.isNear, !conversation.isAgent else { return [] }
        return conversation.turns.filter { turn in
            guard let answer = turn.answer else { return false }
            return !turn.sent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Encodes a NEAR AI Gateway chat as Letta Trajectory v1 JSON bytes.
    /// Format verified against TraceCommons `crates/trace-commons-contributor-sources/src/source/trajectory.rs`:
    /// - First record: `{"role":"meta","source":"cloak","model":"Qwen/Qwen3.8-27B"}`
    /// - Followed by alternating `user` and `assistant` records with strictly
    ///   monotonic RFC 3339 UTC `timestamp` and non-empty `content`.
    public static func encode(_ conversation: Conversation, model: String = Near.model) throws(Failure) -> Data {
        guard conversation.isNear, !conversation.isAgent else { throw .notNearChat }
        let answered = eligibleTurns(in: conversation)
        guard !answered.isEmpty else { throw .noAnsweredTurns }

        var records: [[String: String]] = [
            ["role": "meta", "source": "cloak", "model": model]
        ]
        records.reserveCapacity(1 + answered.count * 2)
        let rfc3339UTC = Date.ISO8601FormatStyle(timeZone: .gmt)
        var step = 0
        for turn in answered {
            guard let answer = turn.answer else { continue }
            let userTimestamp = rfc3339UTC.format(conversation.created.addingTimeInterval(Double(step)))
            step += 1
            let assistantTimestamp = rfc3339UTC.format(conversation.created.addingTimeInterval(Double(step)))
            step += 1
            records.append([
                "role": "user",
                "timestamp": userTimestamp,
                "content": turn.sent,
            ])
            records.append([
                "role": "assistant",
                "timestamp": assistantTimestamp,
                "content": answer,
            ])
        }

        do {
            return try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw .io("Couldn't serialize trace: \(error.localizedDescription)")
        }
    }

    /// Prepares the owner-only `Traces` folder, excluded from Time Machine
    /// backups and Spotlight indexing.
    public static func prepareFolder(_ folder: URL) throws(Failure) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableFolder = folder
            try mutableFolder.setResourceValues(values)
            let noIndex = folder.appending(path: ".metadata_never_index")
            if !fm.fileExists(atPath: noIndex.path) {
                try Data().write(to: noIndex, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: noIndex.path)
            }
        } catch {
            throw .io(error.localizedDescription)
        }
    }

    /// File URL for a conversation's exported trajectory JSON inside `folder`.
    public static func fileURL(for conversationID: UUID, in folder: URL) -> URL {
        folder.appending(path: "\(conversationID.uuidString.lowercased()).json")
    }

    /// Writes `conversation` to `<folder>/<id>.json` with owner-only `0600`
    /// permissions, atomically.
    @discardableResult
    public static func export(_ conversation: Conversation, to folder: URL, model: String = Near.model) throws(Failure) -> ExportedFile {
        let data = try encode(conversation, model: model)
        try prepareFolder(folder)
        let target = fileURL(for: conversation.id, in: folder)
        do {
            try data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
            let modified = (attrs[.modificationDate] as? Date) ?? .now
            let turns = eligibleTurns(in: conversation).count
            return ExportedFile(conversationID: conversation.id, url: target, bytes: data.count, modifiedAt: modified, turnCount: turns)
        } catch {
            throw .io(error.localizedDescription)
        }
    }

    /// Removes one exported trace file from `folder`. Missing file is a no-op.
    public static func remove(conversationID: UUID, from folder: URL) throws(Failure) {
        let target = fileURL(for: conversationID, in: folder)
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return }
        do {
            try fm.removeItem(at: target)
        } catch {
            throw .io(error.localizedDescription)
        }
    }

    /// Removes all exported `.json` trace files in `folder`, leaving the
    /// folder marker intact.
    public static func removeAll(in folder: URL) throws(Failure) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return }
        do {
            let items = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            for item in items where item.pathExtension.lowercased() == "json" {
                try fm.removeItem(at: item)
            }
        } catch {
            throw .io(error.localizedDescription)
        }
    }

    /// Scans `folder` for all valid `<uuid>.json` trace files exported by Cloak.
    public static func scan(in folder: URL) -> [UUID: ExportedFile] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        var found: [UUID: ExportedFile] = [:]
        for item in items where item.pathExtension.lowercased() == "json" {
            let stem = item.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: stem) else { continue }
            let vals = try? item.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let bytes = vals?.fileSize ?? 0
            let modified = vals?.contentModificationDate ?? .distantPast
            let turnCount = Self.exportedTurnCount(at: item)
            found[id] = ExportedFile(conversationID: id, url: item, bytes: bytes, modifiedAt: modified, turnCount: turnCount)
        }
        return found
    }

    /// Approximate byte size of `conversation` if exported now (0 if ineligible).
    public static func estimatedBytes(for conversation: Conversation) -> Int {
        (try? encode(conversation).count) ?? 0
    }

    private static func exportedTurnCount(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return 0 }
        return records.filter { ($0["role"] as? String) == "assistant" }.count
    }
}
