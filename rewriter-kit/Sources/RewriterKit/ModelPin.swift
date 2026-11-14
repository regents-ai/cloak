import CryptoKit
import Foundation

/// One model entry of `reference/models.json`, which is built into the worker:
/// the files the worker may load and the chat template settings frozen with
/// them.
public struct ModelPin: Sendable {
    public struct File: Decodable, Sendable {
        public let path: String
        let size: Int
        let sha256: String
    }

    /// The reply grammar a model decodes under (decision 9 in docs/plan.md):
    /// a file in reference/, pinned by its sha256.
    public struct Grammar: Decodable, Sendable {
        public let file: String
        public let sha256: String
    }

    public let name: String
    public let files: [File]
    public let chatTemplateContext: [String: Bool]
    public let grammar: Grammar?

    /// Only models a worker runs carry an `engine` (decision 8 in
    /// docs/plan.md) and frozen chat template settings
    /// (`chat_template_context`); a worker loads only its own engine's models.
    /// Only the llama worker applies a grammar.
    public static func load(name: String, engine: String) throws -> ModelPin {
        struct Entry: Decodable {
            let name: String
            let engine: String?
            let files: [File]
            let chat_template_context: [String: Bool]?
            let grammar: Grammar?
        }
        struct Manifest: Decodable { let models: [Entry] }
        let models = try JSONDecoder().decode(Manifest.self, from: Data(PackageResources.models_json)).models
        guard let entry = models.first(where: { $0.name == name }) else {
            throw WorkerError("no pinned model named \(name)")
        }
        guard entry.engine == engine else {
            throw WorkerError("\(name) is not a model for the \(engine) worker")
        }
        guard let context = entry.chat_template_context else {
            throw WorkerError("\(name) has no frozen chat template settings")
        }
        guard entry.grammar == nil || engine == "llama" else {
            throw WorkerError("\(name) pins a grammar, which only the llama worker applies")
        }
        return ModelPin(name: entry.name, files: entry.files, chatTemplateContext: context, grammar: entry.grammar)
    }

    /// The directory must hold exactly the pinned files, as regular files with
    /// the pinned size and sha256. Anything else stops the worker.
    public func verify(directory: URL) throws {
        var found = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        // The sandbox hides folders outside the models folder; an unreadable
        // folder must fail as unreadable, not look empty.
        var unreadable: URL?
        guard let entries = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [],
            errorHandler: { url, _ in unreadable = url; return false })
        else {
            throw WorkerError("cannot read \(directory.path)")
        }
        let root = directory.standardizedFileURL.path + "/"
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(root.count))
            guard values.isRegularFile == true else { throw WorkerError("\(path) is not a regular file") }
            found.insert(path)
        }
        if let unreadable { throw WorkerError("cannot read \(unreadable.path)") }
        let pinned = Set(files.map(\.path))
        guard found == pinned else {
            let extra = found.subtracting(pinned).sorted(), missing = pinned.subtracting(found).sorted()
            throw WorkerError("files differ from the pin: extra \(extra), missing \(missing)")
        }
        for file in files {
            let url = directory.appending(path: file.path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size == file.size, try digest(url) == file.sha256 else {
                throw WorkerError("\(file.path) does not match the pin")
            }
        }
    }

    /// The file's sha256, read 8 MiB at a time. FileHandle's reads are
    /// autoreleased, so each block is read inside a pool of its own and is
    /// gone before the next is read. Without one every block stayed until the
    /// thread next drained its pool: the whole file, which the llama worker
    /// then held beside the model as it loaded.
    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while try autoreleasepool(invoking: {
            guard let block = try handle.read(upToCount: 8 << 20), !block.isEmpty else { return false }
            hash.update(data: block)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct WorkerError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
