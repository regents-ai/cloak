import CloakControl
import CryptoKit
import Foundation
import Metal

/// A requirement that failed: why, and the technical detail.
public struct Failure: Error, Sendable, Equatable {
    public var reason: Reason
    public var detail: String

    public init(_ reason: Reason, _ detail: String) {
        self.reason = reason
        self.detail = detail
    }
}

/// The checks made before anything starts, in order: the Mac, each part
/// against its pin, and the model's files. The worker checks the model's
/// files against their sha256 pins itself as it loads them; here each pinned
/// file must be present at its pinned size, so a missing or partial download
/// is named before anything starts.
enum Checks {
    /// The Mac: whether it has Apple silicon, its memory, and the most
    /// memory Metal recommends its graphics hold
    /// (`recommendedMaxWorkingSetSize`), nil when that cannot be read.
    struct Hardware: Sendable {
        var appleSilicon: Bool
        var memory: UInt64
        var graphicsLimit: UInt64?

        static var current: Hardware {
            var arm: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let found = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0
            return Hardware(
                appleSilicon: found && arm == 1, memory: ProcessInfo.processInfo.physicalMemory,
                graphicsLimit: MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize)
        }
    }

    /// Kept spare within the graphics limit, for what the model's figure
    /// cannot see: llama.cpp's own margin. With `keptForMacOS`, the memory
    /// budget of the Llama app (`deviceMemoryBudgetMb`, decision 14 in
    /// docs/plan.md).
    static let graphicsSpare: UInt64 = 1 << 30
    /// Kept out of Cloak's reach for macOS and other apps; a fixed amount,
    /// since the desktop needs no less on a small Mac.
    static let keptForMacOS: UInt64 = 4 << 30

    /// Each check's finding, and the failure it stands for when it failed.
    static func run(_ manifest: Manifest, _ layout: Layout, hardware: Hardware) async -> [(Finding, Failure?)] {
        var results = [hardwareCheck(hardware, model: manifest.modelMemory, cloak: manifest.cloakMemory)]
        for pin in manifest.pins {
            results.append(await pinCheck(pin, at: layout.url(pin)))
        }
        results.append(modelCheck(manifest.model, in: layout.model(manifest)))
        return results
    }

    /// Passes a Mac with Apple silicon whose graphics limit holds the
    /// model's `model` bytes with `graphicsSpare` to spare, and whose memory
    /// holds all of Cloak's `cloak` bytes with `keptForMacOS` kept for
    /// macOS. A graphics limit that cannot be read fails.
    static func hardwareCheck(_ hardware: Hardware, model: UInt64, cloak: UInt64) -> (Finding, Failure?) {
        let text = Memory.text
        let cloakRoom = max(hardware.memory, keptForMacOS) - keptForMacOS
        let modelRoom = hardware.graphicsLimit.map { max($0, graphicsSpare) - graphicsSpare }
        let modelLine = if let limit = hardware.graphicsLimit, let modelRoom {
            "Model: needs \(text(model)); room \(text(modelRoom)) (graphics limit \(text(limit)), less \(text(graphicsSpare)) spare)."
        } else {
            "Model: needs \(text(model)); the graphics limit cannot be read."
        }
        let detail = [
            "\(hardware.appleSilicon ? "Apple silicon" : "Not Apple silicon, which Cloak needs"); \(text(hardware.memory)) of memory.",
            modelLine,
            "All of Cloak: needs \(text(cloak)); room \(text(cloakRoom)) (\(text(hardware.memory)), less \(text(keptForMacOS)) for macOS).",
        ].joined(separator: " ")
        let passed = hardware.appleSilicon && modelRoom.map { model <= $0 } == true && cloak <= cloakRoom
        return (Finding(name: "Mac", passed: passed, detail: detail), passed ? nil : Failure(.unsupportedHardware, detail))
    }

    static func pinCheck(_ pin: Manifest.Pin, at url: URL) async -> (Finding, Failure?) {
        let name = pin.part.rawValue
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            let detail = "\(url.path) is missing"
            return (Finding(name: name, passed: false, detail: detail), Failure(.partMissing, "\(name): \(detail)"))
        }
        let digest: String
        do {
            digest = try await sha256(url)
        } catch {
            let detail = "cannot read \(url.path): \(error)"
            return (Finding(name: name, passed: false, detail: detail), Failure(.partMissing, "\(name): \(detail)"))
        }
        guard digest == pin.sha256 else {
            let detail = "\(url.path) has sha256 \(digest), pinned \(pin.sha256)"
            return (Finding(name: name, passed: false, detail: detail), Failure(.partChanged, "\(name): \(detail)"))
        }
        return (Finding(name: name, passed: true, detail: "\(url.path) matches its pin"), nil)
    }

    static func modelCheck(_ model: Manifest.Model, in directory: URL) -> (Finding, Failure?) {
        let wrong = model.files.filter { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appending(path: file.path).path)
            return attributes?[.type] as? FileAttributeType != .typeRegular || (attributes?[.size] as? Int) != file.size
        }
        guard wrong.isEmpty else {
            let detail = "\(directory.path): missing or incomplete: \(wrong.map(\.path).joined(separator: ", "))"
            return (Finding(name: "model", passed: false, detail: detail), Failure(.modelMissing, detail))
        }
        let bytes = model.files.reduce(0) { $0 + $1.size }
        return (Finding(name: "model", passed: true, detail: "\(model.name): \(model.files.count) files, \(bytes) bytes in \(directory.path)"), nil)
    }

    @concurrent
    static func sha256(_ url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 8 << 20), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
