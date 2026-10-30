import CryptoKit
import Foundation

/// One model entry of `reference/models.json`: the files the worker may load
/// and the chat template settings frozen with them.
struct ModelPin: Sendable {
    struct File: Decodable, Sendable {
        let path: String
        let size: Int
        let sha256: String
    }

    let name: String
    let files: [File]
    let chatTemplateContext: [String: Bool]

    /// Only models whose chat template settings are frozen carry
    /// `chat_template_context`; the worker loads no other.
    static func load(manifest: URL, name: String) throws -> ModelPin {
        struct Entry: Decodable {
            let name: String
            let files: [File]
            let chat_template_context: [String: Bool]?
        }
        struct Manifest: Decodable { let models: [Entry] }
        let models = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest)).models
        guard let entry = models.first(where: { $0.name == name }) else {
            throw WorkerError("no model named \(name) in \(manifest.path)")
        }
        guard let context = entry.chat_template_context else {
            throw WorkerError("\(name) has no frozen chat template settings")
        }
        return ModelPin(name: entry.name, files: entry.files, chatTemplateContext: context)
    }

    /// The directory must hold exactly the pinned files, as regular files with
    /// the pinned size and sha256. Anything else stops the worker.
    func verify(directory: URL) throws {
        var found = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
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

    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 8 << 20), !block.isEmpty {
            hash.update(data: block)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct WorkerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
