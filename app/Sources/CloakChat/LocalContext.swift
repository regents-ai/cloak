import AppKit
import Contacts
import Darwin
import EventKit
import Foundation
import ImageIO
import PDFKit
import Vision

/// Hermes-compatible local memory (`USER.md` and `MEMORY.md`), stored owner-only
/// on this Mac and excluded from Spotlight and Time Machine. Used strictly in
/// Local Mode — never read or transmitted for cloud modes.
public struct LocalMemoryStore: Sendable {
    /// Hermes-compatible character limits.
    public static let userLimit = 1_375
    public static let memoryLimit = 2_200

    public let folder: URL
    public let hermesFolder: URL

    public init(folder: URL = Self.defaultFolder, hermesFolder: URL = Self.defaultHermesFolder) {
        self.folder = folder
        self.hermesFolder = hermesFolder
    }

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Regents Cloak/memories", directoryHint: .isDirectory)
    }

    public static var defaultHermesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".hermes/memories", directoryHint: .isDirectory)
    }

    public var userFile: URL { folder.appending(path: "USER.md") }
    public var memoryFile: URL { folder.appending(path: "MEMORY.md") }
    public var hermesUserFile: URL { hermesFolder.appending(path: "USER.md") }
    public var hermesMemoryFile: URL { hermesFolder.appending(path: "MEMORY.md") }

    public struct Contents: Equatable, Sendable {
        public var user: String
        public var memory: String

        public init(user: String = "", memory: String = "") {
            self.user = user
            self.memory = memory
        }

        public var isEmpty: Bool {
            user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public static func clamped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    /// Reads `USER.md` and `MEMORY.md` from Cloak's memory folder. When
    /// `syncHermes` is true and a Hermes file exists and is newer (or Cloak's
    /// file is empty), reads from `~/.hermes/memories/` and mirrors locally.
    public func load(syncHermes: Bool = false) -> Contents {
        var user = readTrimmed(userFile, limit: Self.userLimit)
        var memory = readTrimmed(memoryFile, limit: Self.memoryLimit)

        if syncHermes {
            if let importedUser = preferHermesIfNewer(local: userFile, localText: user, hermes: hermesUserFile, limit: Self.userLimit) {
                user = importedUser
            }
            if let importedMemory = preferHermesIfNewer(local: memoryFile, localText: memory, hermes: hermesMemoryFile, limit: Self.memoryLimit) {
                memory = importedMemory
            }
        }
        return Contents(user: user, memory: memory)
    }

    /// Writes clamped `USER.md` and `MEMORY.md` into Cloak's owner-only folder
    /// (and optionally mirrors them into `~/.hermes/memories/`).
    public func save(_ contents: Contents, syncHermes: Bool = false) throws {
        try ensurePrivateFolder(folder)
        let user = Self.clamped(contents.user, limit: Self.userLimit)
        let memory = Self.clamped(contents.memory, limit: Self.memoryLimit)
        try writePrivateFile(user, to: userFile)
        try writePrivateFile(memory, to: memoryFile)

        if syncHermes {
            try ensurePrivateFolder(hermesFolder)
            try writePrivateFile(user, to: hermesUserFile)
            try writePrivateFile(memory, to: hermesMemoryFile)
        }
    }

    /// Imports existing `~/.hermes/memories/{USER.md,MEMORY.md}` into Cloak's
    /// local store if present, returning the imported contents.
    public func importFromHermes() throws -> Contents? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hermesUserFile.path) || fm.fileExists(atPath: hermesMemoryFile.path) else {
            return nil
        }
        let imported = Contents(
            user: readTrimmed(hermesUserFile, limit: Self.userLimit),
            memory: readTrimmed(hermesMemoryFile, limit: Self.memoryLimit))
        try save(imported, syncHermes: false)
        return imported
    }

    public var hasHermesMemories: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: hermesUserFile.path) || fm.fileExists(atPath: hermesMemoryFile.path)
    }

    private func readTrimmed(_ url: URL, limit: Int) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return Self.clamped(text, limit: limit)
    }

    private func preferHermesIfNewer(local: URL, localText: String, hermes: URL, limit: Int) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hermes.path) else { return nil }
        let hermesText = readTrimmed(hermes, limit: limit)
        guard !hermesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return hermesText
        }
        let localDate = (try? local.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let hermesDate = (try? hermes.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return hermesDate > localDate ? hermesText : nil
    }

    private func ensurePrivateFolder(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        var excluded = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        let neverIndex = dir.appending(path: ".metadata_never_index")
        if !fm.fileExists(atPath: neverIndex.path) {
            fm.createFile(atPath: neverIndex.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }

    private func writePrivateFile(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Concise, non-identifying local hardware & clock snapshot for Local Mode.
/// Never reads serial numbers, UUIDs, usernames, or network addresses.
public enum MacSnapshot {
    public static func current(now: Date = .now) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEEE, yyyy-MM-dd HH:mm"
        let tz = TimeZone.current
        let tzName = tz.abbreviation(for: now) ?? tz.identifier
        let dateLine = "\(dateFormatter.string(from: now)) \(tzName) (\(tz.identifier))"

        let model = sysctlString("hw.model") ?? "Mac"
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let cores = ProcessInfo.processInfo.processorCount
        let ramGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0).rounded())
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        var lines = [
            "Current local time: \(dateLine)",
            "Mac model: \(model)",
            "CPU: \(chip) (\(cores) cores)",
            "Memory: \(ramGB) GB unified RAM",
            "OS: macOS \(osVersion)",
        ]
        if let freeGB = freeDiskGigabytes() {
            lines.append("Available disk space: \(freeGB) GB")
        }
        return lines.joined(separator: "\n")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func freeDiskGigabytes() -> Int? {
        let root = URL(filePath: "/")
        guard let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let bytes = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Int(bytes / 1_000_000_000)
    }
}

/// A local file, PDF, document, or OCR'd image explicitly attached to one Local Mode turn.
public struct LocalAttachment: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case file
        case pdf
        case document
        case image
    }

    public enum ReadError: LocalizedError, Sendable {
        case unreadable(String)
        case empty(String)
        case imageNoText(String)
        case unsupportedBinary(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                "Couldn't read \"\(name)\"."
            case .empty(let name):
                "\"\(name)\" has no extractable text."
            case .imageNoText(let name):
                "\"\(name)\" has no readable text. Local models are text-only — attach images with text (OCR), PDFs, documents, or text/code files."
            case .unsupportedBinary(let name):
                "\"\(name)\" isn't a supported PDF, document, image, or text file."
            }
        }
    }

    public static let maxCharacters = 12_000
    public static let maxFileBytes = 25 * 1024 * 1024
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "tiff", "tif", "bmp", "gif",
    ]
    private static let richDocumentExtensions: Set<String> = [
        "rtf", "rtfd", "docx", "doc", "odt",
    ]

    public let id: UUID
    public let name: String
    public let kind: Kind
    public let text: String
    public let truncated: Bool

    public init(id: UUID = UUID(), name: String, kind: Kind, text: String, truncated: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.text = text
        self.truncated = truncated
    }

    public static func from(url: URL) throws -> LocalAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        // Resolve symlinks before inspecting directory/file size so a tiny
        // symlink cannot bypass the 25 MB size cap or directory guard.
        let resolved = url.resolvingSymlinksInPath()
        let name = url.lastPathComponent
        let ext = resolved.pathExtension.lowercased().isEmpty ? url.pathExtension.lowercased() : resolved.pathExtension.lowercased()
        let values = try? resolved.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            guard ext == "rtfd" else {
                throw ReadError.unsupportedBinary(name)
            }
            let bundleSize = directoryByteSize(at: resolved, limit: maxFileBytes + 1)
            if bundleSize > maxFileBytes {
                throw ReadError.unreadable("\(name) (exceeds 25 MB)")
            }
        } else if let size = values?.fileSize, size > maxFileBytes {
            throw ReadError.unreadable("\(name) (exceeds 25 MB)")
        }

        if ext == "pdf" {
            return try fromPDF(url: resolved, name: name)
        }

        if imageExtensions.contains(ext) {
            return try fromImage(url: resolved, name: name)
        }

        if richDocumentExtensions.contains(ext) {
            return try fromRichDocument(url: resolved, name: name)
        }

        guard let data = try? Data(contentsOf: resolved) else {
            throw ReadError.unreadable(name)
        }
        // Check UTF-16 BOM before rejecting NUL bytes so UTF-16 text files work.
        let decoded: String?
        if data.count >= 2 && ((data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF)) {
            decoded = String(data: data, encoding: .utf16)
        } else {
            if data.prefix(4096).contains(0) {
                throw ReadError.unsupportedBinary(name)
            }
            decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        guard let raw = decoded else {
            throw ReadError.unsupportedBinary(name)
        }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ReadError.empty(name) }
        let truncated = cleaned.count > maxCharacters
        return LocalAttachment(
            name: name, kind: .file,
            text: truncated ? String(cleaned.prefix(maxCharacters)) : cleaned,
            truncated: truncated)
    }

    private static func directoryByteSize(at dir: URL, limit: Int) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsPackageDescendants])
        else { return 0 }
        var total = 0
        for case let item as URL in enumerator {
            if let sz = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += sz
                if total >= limit { return total }
            }
        }
        return total
    }

    private static func fromPDF(url: URL, name: String) throws -> LocalAttachment {
        guard let doc = PDFDocument(url: url) else {
            throw ReadError.unreadable(name)
        }
        if doc.isLocked {
            throw ReadError.unreadable("\(name) (password-protected PDF)")
        }
        var extracted = ""
        for pageIndex in 0..<doc.pageCount {
            if let pageText = doc.page(at: pageIndex)?.string, !pageText.isEmpty {
                if !extracted.isEmpty { extracted += "\n\n" }
                extracted += pageText
                if extracted.count >= maxCharacters + 200 { break }
            }
        }
        var cleaned = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fall back to on-device Vision OCR for scanned/image-only PDFs.
        if cleaned.isEmpty {
            cleaned = ocrPDF(doc, maxPages: 6).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !cleaned.isEmpty else { throw ReadError.empty(name) }
        let truncated = cleaned.count > maxCharacters
        return LocalAttachment(
            name: name, kind: .pdf,
            text: truncated ? String(cleaned.prefix(maxCharacters)) : cleaned,
            truncated: truncated)
    }

    private static func fromRichDocument(url: URL, name: String) throws -> LocalAttachment {
        // AppKit's RTF/DOCX/ODT importers must run on the main thread on macOS.
        let extract: () -> String? = {
            (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        let rawString: String?
        if Thread.isMainThread {
            rawString = extract()
        } else {
            rawString = DispatchQueue.main.sync(execute: extract)
        }
        guard let rawString else {
            throw ReadError.unreadable(name)
        }
        let cleaned = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ReadError.empty(name) }
        let truncated = cleaned.count > maxCharacters
        return LocalAttachment(
            name: name, kind: .document,
            text: truncated ? String(cleaned.prefix(maxCharacters)) : cleaned,
            truncated: truncated)
    }

    private static func fromImage(url: URL, name: String) throws -> LocalAttachment {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ReadError.unreadable(name)
        }
        let ocrText = recognizeText(in: cgImage).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ocrText.isEmpty else {
            throw ReadError.imageNoText(name)
        }
        let body = "Image: \(name) (\(cgImage.width)×\(cgImage.height))\nExtracted text (on-device OCR):\n\(ocrText)"
        let truncated = body.count > maxCharacters
        return LocalAttachment(
            name: name, kind: .image,
            text: truncated ? String(body.prefix(maxCharacters)) : body,
            truncated: truncated)
    }

    private static func ocrPDF(_ doc: PDFDocument, maxPages: Int) -> String {
        var pages: [String] = []
        let limit = min(doc.pageCount, maxPages)
        for index in 0..<limit {
            guard let page = doc.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let scale: CGFloat = min(2.0, 2000.0 / max(bounds.width, bounds.height))
            let width = max(Int((bounds.width * scale).rounded()), 1)
            let height = max(Int((bounds.height * scale).rounded()), 1)
            guard let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            guard let cgImage = ctx.makeImage() else { continue }
            let text = recognizeText(in: cgImage).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                pages.append(text)
            }
        }
        return pages.joined(separator: "\n\n")
    }

    private static func recognizeText(in cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
            let observations = request.results
        else { return "" }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

/// Read-only keyword search over user-approved local folders for Local Mode.
/// Strictly skips hidden files/directories, `.env*`, private keys, and binary files.
public enum ApprovedFolderSearch {
    public struct Match: Equatable, Sendable {
        public let relativePath: String
        public let snippet: String
        public let score: Int
    }

    private static let allowedExtensions: Set<String> = [
        "md", "markdown", "txt", "json", "csv", "tsv", "yaml", "yml", "toml",
        "xml", "html", "css", "swift", "py", "js", "ts", "tsx", "jsx", "rs",
        "go", "c", "h", "cpp", "hpp", "m", "mm", "java", "kt", "rb", "sh",
        "zsh", "sql", "ex", "exs", "org", "tex", "log", "conf", "ini",
    ]

    private static let skippedDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "DerivedData",
        "target", "dist", "build", ".venv", "venv", "__pycache__", ".next",
        ".cache", "Pods", "Carthage",
    ]

    private static let secretExtensions: Set<String> = [
        "pem", "key", "p12", "p8", "pfx", "kdbx", "keystore", "jks", "age", "gpg", "asc",
    ]

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "what", "when", "where",
        "which", "who", "how", "why", "are", "was", "were", "have", "has", "had",
        "can", "could", "would", "should", "will", "about", "into", "your", "you",
        "please", "tell", "show", "find", "list", "give", "make", "does", "did",
    ]

    public static func search(
        query: String,
        folders: [String],
        maxMatches: Int = 4,
        maxTotalCharacters: Int = 4_000
    ) -> [Match] {
        guard !folders.isEmpty else { return [] }
        let terms = extractTerms(from: query)
        guard !terms.isEmpty else { return [] }

        let fm = FileManager.default
        var candidates: [Match] = []
        var scanned = 0
        let maxFilesToScan = 600
        let maxFileBytes = 512 * 1024

        for folderPath in folders {
            let rootURL = URL(filePath: folderPath).resolvingSymlinksInPath().standardizedFileURL
            guard fm.fileExists(atPath: rootURL.path) else { continue }
            let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            let rootComponents = rootURL.pathComponents.count

            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isHiddenKey],
                options: [.skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                if scanned >= maxFilesToScan { break }
                let resolvedFileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
                let name = resolvedFileURL.lastPathComponent
                let lowerName = name.lowercased()

                // Strictly skip dotfiles, .env variants, and ignored build/dependency directories.
                if name.hasPrefix(".") || lowerName == "env" || lowerName.hasPrefix(".env")
                    || lowerName.contains("secret") && lowerName.hasSuffix(".json")
                {
                    if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    let depth = resolvedFileURL.pathComponents.count - rootComponents
                    if depth >= 4 || skippedDirectoryNames.contains(name) {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                guard values?.isRegularFile == true else { continue }
                let ext = resolvedFileURL.pathExtension.lowercased()
                guard !secretExtensions.contains(ext), allowedExtensions.contains(ext) else { continue }
                if let size = values?.fileSize, size == 0 || size > maxFileBytes { continue }

                scanned += 1
                guard let content = try? String(contentsOf: resolvedFileURL, encoding: .utf8), !content.isEmpty else { continue }

                let fullPath = resolvedFileURL.path
                let relative = fullPath.hasPrefix(rootPrefix) ? String(fullPath.dropFirst(rootPrefix.count)) : name
                let displayPath = "\(rootURL.lastPathComponent)/\(relative)"
                let lowerPath = displayPath.lowercased()
                let lowerContent = content.lowercased()

                var score = 0
                var firstMatchRange: Range<String.Index>?
                for term in terms {
                    if lowerPath.contains(term) { score += 5 }
                    if let range = lowerContent.range(of: term) {
                        score += 3
                        if firstMatchRange == nil { firstMatchRange = range }
                    }
                }
                guard score > 0 else { continue }

                let snippet = makeSnippet(from: content, lowerContent: lowerContent, around: firstMatchRange, maxLength: 900)
                candidates.append(Match(relativePath: displayPath, snippet: snippet, score: score))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.relativePath < rhs.relativePath
        }

        var selected: [Match] = []
        var usedChars = 0
        for match in candidates.prefix(maxMatches) {
            let cost = match.relativePath.count + match.snippet.count + 24
            if usedChars + cost > maxTotalCharacters, !selected.isEmpty { break }
            selected.append(match)
            usedChars += cost
        }
        return selected
    }

    private static func extractTerms(from query: String) -> [String] {
        let rawTokens = query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        var unique: [String] = []
        for token in rawTokens where token.count >= 3 && !stopWords.contains(token) {
            if !unique.contains(token) {
                unique.append(token)
            }
            if unique.count >= 12 { break }
        }
        return unique
    }

    private static func makeSnippet(
        from content: String,
        lowerContent: String,
        around range: Range<String.Index>?,
        maxLength: Int
    ) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        guard let range else {
            return String(trimmed.prefix(maxLength)) + "…"
        }
        // Map offset safely in `content`.
        let offset = lowerContent.distance(from: lowerContent.startIndex, to: range.lowerBound)
        let startOffset = max(0, offset - 180)
        let startIdx = content.index(content.startIndex, offsetBy: min(startOffset, content.count))
        let endIdx = content.index(startIdx, offsetBy: min(maxLength, content.distance(from: startIdx, to: content.endIndex)))
        let prefix = startOffset > 0 ? "…" : ""
        let suffix = endIdx < content.endIndex ? "…" : ""
        return prefix + String(content[startIdx..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }
}

/// Strictly opt-in, read-only macOS Personal Data connectors (Calendar, Reminders,
/// Contacts) for Local Mode. Permission prompts are triggered ONLY by explicit
/// `request*Access()` calls from Settings when the user flips a toggle ON.
public enum PersonalDataConnectors {
    public enum AccessStatus: String, Equatable, Sendable {
        case notDetermined
        case authorized
        case denied
        case restricted

        public var label: String {
            switch self {
            case .notDetermined: "Not requested"
            case .authorized: "Allowed"
            case .denied: "Denied in System Settings"
            case .restricted: "Restricted"
            }
        }
    }

    public static func calendarStatus() -> AccessStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied, .writeOnly: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    public static func remindersStatus() -> AccessStatus {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied, .writeOnly: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    public static func contactsStatus() -> AccessStatus {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    public static func requestCalendarAccess() async -> Bool {
        let store = EKEventStore()
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    public static func requestRemindersAccess() async -> Bool {
        let store = EKEventStore()
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    public static func requestContactsAccess() async -> Bool {
        let store = CNContactStore()
        return (try? await store.requestAccess(for: .contacts)) ?? false
    }

    /// Reads upcoming calendar events for the next `days` days if already authorized.
    /// Never triggers a permission prompt.
    public static func upcomingCalendarLines(now: Date = .now, days: Int = 7, limit: Int = 15) -> [String] {
        guard calendarStatus() == .authorized else { return [] }
        let store = EKEventStore()
        let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now.addingTimeInterval(Double(days) * 86_400)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d, HH:mm"

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "EEE MMM d"

        return events.map { event in
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "(Untitled event)"
            let when = event.isAllDay
                ? "\(dayFormatter.string(from: event.startDate)) (All day)"
                : formatter.string(from: event.startDate)
            let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if let location {
                return "- \(when): \(title) @ \(location)"
            }
            return "- \(when): \(title)"
        }
    }

    /// Reads incomplete reminders if already authorized. Never triggers a permission prompt.
    public static func openReminderLines(limit: Int = 20) async -> [String] {
        guard remindersStatus() == .authorized else { return [] }
        let store = EKEventStore()
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let lines: [String] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "MMM d"

                let sorted = (reminders ?? []).sorted { lhs, rhs in
                    let lDate = lhs.dueDateComponents?.date ?? .distantFuture
                    let rDate = rhs.dueDateComponents?.date ?? .distantFuture
                    return lDate < rDate
                }
                let formatted = sorted.prefix(limit).map { reminder -> String in
                    let title = reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "(Untitled reminder)"
                    let listName = reminder.calendar?.title.nilIfEmpty
                    let due = reminder.dueDateComponents?.date.map { "due \(formatter.string(from: $0))" }
                    let meta = [listName, due].compactMap { $0 }.joined(separator: ", ")
                    return meta.isEmpty ? "- \(title)" : "- \(title) (\(meta))"
                }
                continuation.resume(returning: formatted)
            }
        }
        return lines
    }

    /// Reads only contacts matching a name/organization mentioned in `query`.
    /// Never dumps the entire address book and never triggers a permission prompt.
    public static func matchingContactLines(for query: String, limit: Int = 8) -> [String] {
        guard contactsStatus() == .authorized else { return [] }
        let tokens = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
        guard !tokens.isEmpty else { return [] }

        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        var seenIDs: Set<String> = []
        var lines: [String] = []
        for token in Array(Set(tokens)).prefix(8) {
            guard lines.count < limit else { break }
            let predicate = CNContact.predicateForContacts(matchingName: token)
            guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) else { continue }
            for contact in contacts {
                guard lines.count < limit else { break }
                guard seenIDs.insert(contact.identifier).inserted else { continue }
                let fullName = [contact.givenName, contact.familyName]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let display = fullName.isEmpty ? contact.organizationName : fullName
                guard !display.isEmpty else { continue }

                var details: [String] = []
                if !contact.organizationName.isEmpty && contact.organizationName != display {
                    details.append(contact.organizationName)
                }
                if let email = contact.emailAddresses.first?.value as String? {
                    details.append(email)
                }
                if let phone = contact.phoneNumbers.first?.value.stringValue {
                    details.append(phone)
                }
                let suffix = details.isEmpty ? "" : " — " + details.joined(separator: " · ")
                lines.append("- \(display)\(suffix)")
            }
        }
        return lines
    }
}

/// Configuration for what local-only context to attach to a Local Mode prompt.
public struct LocalContextOptions: Equatable, Sendable {
    public var shareMacInfo: Bool
    public var useMemory: Bool
    public var syncHermesMemory: Bool
    public var approvedFolders: [String]
    public var useCalendar: Bool
    public var useReminders: Bool
    public var useContacts: Bool

    public init(
        shareMacInfo: Bool = false,
        useMemory: Bool = false,
        syncHermesMemory: Bool = false,
        approvedFolders: [String] = [],
        useCalendar: Bool = false,
        useReminders: Bool = false,
        useContacts: Bool = false
    ) {
        self.shareMacInfo = shareMacInfo
        self.useMemory = useMemory
        self.syncHermesMemory = syncHermesMemory
        self.approvedFolders = approvedFolders
        self.useCalendar = useCalendar
        self.useReminders = useReminders
        self.useContacts = useContacts
    }

    public var hasAnyEnabled: Bool {
        shareMacInfo || useMemory || !approvedFolders.isEmpty || useCalendar || useReminders || useContacts
    }
}

/// Builds a bounded, clearly fenced offline context block for Local Mode turns.
public enum LocalContextBuilder {
    /// Builds the local context string from enabled sources and any explicit
    /// per-turn attachments, or returns `nil` if nothing is enabled or attached.
    public static func build(
        query: String,
        options: LocalContextOptions,
        attachments: [LocalAttachment] = [],
        memoryStore: LocalMemoryStore = LocalMemoryStore(),
        now: Date = .now
    ) async -> String? {
        guard options.hasAnyEnabled || !attachments.isEmpty else { return nil }

        var sections: [String] = []

        if options.shareMacInfo {
            sections.append("## This Mac\n" + MacSnapshot.current(now: now))
        }

        if options.useMemory {
            let mem = memoryStore.load(syncHermes: options.syncHermesMemory)
            let user = mem.user.trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = mem.memory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !user.isEmpty {
                sections.append("## User Profile (USER.md)\n" + user)
            }
            if !notes.isEmpty {
                sections.append("## Local Memory (MEMORY.md)\n" + notes)
            }
        }

        if !options.approvedFolders.isEmpty {
            let matches = ApprovedFolderSearch.search(query: query, folders: options.approvedFolders)
            if !matches.isEmpty {
                let body = matches.map { "### \($0.relativePath)\n\($0.snippet)" }.joined(separator: "\n\n")
                sections.append("## Approved Local Folder Matches\n" + body)
            }
        }

        if options.useCalendar {
            let events = PersonalDataConnectors.upcomingCalendarLines(now: now)
            if !events.isEmpty {
                sections.append("## Upcoming Calendar (Next 7 Days)\n" + events.joined(separator: "\n"))
            }
        }

        if options.useReminders {
            let reminders = await PersonalDataConnectors.openReminderLines()
            if !reminders.isEmpty {
                sections.append("## Open Reminders\n" + reminders.joined(separator: "\n"))
            }
        }

        if options.useContacts {
            let contacts = PersonalDataConnectors.matchingContactLines(for: query)
            if !contacts.isEmpty {
                sections.append("## Matching Contacts\n" + contacts.joined(separator: "\n"))
            }
        }

        if !attachments.isEmpty {
            let body = attachments.map { item -> String in
                let note = item.truncated ? " (truncated)" : ""
                return "### \(item.name)\(note)\n\(item.text)"
            }.joined(separator: "\n\n")
            sections.append("## Attached Local Files\n" + body)
        }

        guard !sections.isEmpty else { return nil }
        return """
            [Local Context — stays strictly on this Mac; use when relevant to answer the user's request]
            \(sections.joined(separator: "\n\n"))
            [/Local Context]
            """
    }

    /// Formats only the explicitly attached files into a context block so
    /// follow-up turns in the same Local session retain prior attached files.
    public static func attachmentsBlock(for attachments: [LocalAttachment]) -> String? {
        guard !attachments.isEmpty else { return nil }
        let body = attachments.map { item -> String in
            let note = item.truncated ? " (truncated)" : ""
            return "### \(item.name)\(note)\n\(item.text)"
        }.joined(separator: "\n\n")
        return """
            [Local Context — stays strictly on this Mac; use when relevant to answer the user's request]
            ## Attached Local Files
            \(body)
            [/Local Context]
            """
    }

    /// Prepends `context` onto the latest user message in `prompt`, preserving
    /// alternating `user`/`assistant` message structure required by local workers.
    public static func inject(_ context: String?, into prompt: String) -> String {
        guard let context, !context.isEmpty else { return prompt }
        return "\(context)\n\nUser message:\n\(prompt)"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
