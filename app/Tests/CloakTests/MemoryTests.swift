@testable import CloakSupervisor
import Foundation
import Testing

/// The Mac check's memory budget, over injected hardware, for a model that
/// needs 7 GiB and a Cloak that needs 10 GiB: the model within the graphics
/// limit less 1 GiB, and all of Cloak within the memory less 4 GiB.
struct BudgetTests {
    static let model: UInt64 = 7 << 30
    static let cloak: UInt64 = 10 << 30

    @Test(arguments: [
        // A 16 GB Mac, whose graphics limit is about 10.67 GiB.
        (Checks.Hardware(appleSilicon: true, memory: 16 << 30, graphicsLimit: 11_453_251_584), true),
        // An 8 GB Mac, about 5.33 GiB.
        (Checks.Hardware(appleSilicon: true, memory: 8 << 30, graphicsLimit: 5_726_623_744), false),
        // A graphics limit that cannot be read.
        (Checks.Hardware(appleSilicon: true, memory: 64 << 30, graphicsLimit: nil), false),
        // The graphics limit binds: exactly enough, then a byte short.
        (Checks.Hardware(appleSilicon: true, memory: 64 << 30, graphicsLimit: 8 << 30), true),
        (Checks.Hardware(appleSilicon: true, memory: 64 << 30, graphicsLimit: (8 << 30) - 1), false),
        // The memory binds: exactly enough, then a byte short.
        (Checks.Hardware(appleSilicon: true, memory: 14 << 30, graphicsLimit: 9 << 30), true),
        (Checks.Hardware(appleSilicon: true, memory: (14 << 30) - 1, graphicsLimit: 9 << 30), false),
        // Room for everything, without Apple silicon.
        (Checks.Hardware(appleSilicon: false, memory: 64 << 30, graphicsLimit: 48 << 30), false),
    ])
    func theMacPassesOnlyWhenBothLimitsHoldOnAppleSilicon(hardware: Checks.Hardware, passes: Bool) {
        let (finding, failure) = Checks.hardwareCheck(hardware, model: Self.model, cloak: Self.cloak)
        #expect(finding.passed == passes)
        #expect(failure?.reason == (passes ? nil : .unsupportedHardware))
    }

    /// A graphics limit below the spare, or memory below what macOS keeps,
    /// leaves no room rather than wrapping round.
    @Test func limitsBelowWhatIsKeptLeaveNoRoom() {
        let tiny = Checks.Hardware(appleSilicon: true, memory: 2 << 30, graphicsLimit: 512 << 20)
        #expect(!Checks.hardwareCheck(tiny, model: 1, cloak: 1).0.passed)
    }
}

/// What Cloak holds in memory: whole only when every part was read.
struct MemoryTests {
    @Test func theTotalIsTheSumWhenEveryPartWasRead() {
        let memory = Memory(parts: [
            .init(name: "app", footprint: 90 << 20),
            .init(name: "tor", footprint: 20 << 20),
            .init(name: "cloak-rewriter-llama", footprint: 6 << 30),
            .init(name: "virtual machine", footprint: 512 << 20),
        ])
        #expect(memory.total == (90 << 20) + (20 << 20) + (6 << 30) + (512 << 20))
    }

    @Test(arguments: 0..<3)
    func anyPartNotReadLeavesNoTotal(missing: Int) {
        var memory = Memory(parts: [
            .init(name: "app", footprint: 90 << 20),
            .init(name: "tor", footprint: 20 << 20),
            .init(name: "virtual machine", footprint: 512 << 20),
        ])
        memory.parts[missing].footprint = nil
        #expect(memory.total == nil)
    }

    /// This process and the processes it started are read, the way the app
    /// reads itself, tor and the worker.
    @Test func aReadingHasThisProcessAndEachProcessItStarted() throws {
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        let memory = Memory.read(guest: false)
        let app = try #require(memory.parts.first)
        #expect(app.name == "app" && (app.footprint ?? 0) > 0)
        #expect(memory.parts.contains { $0.name == "sleep" && $0.footprint != nil })
        #expect(memory.total == memory.parts.compactMap(\.footprint).reduce(0, +))
    }

    /// A started guest whose virtual machine cannot be found leaves the
    /// reading without a total, rather than a smaller one.
    @Test(.enabled("no virtual machine runs for this process") {
        !Memory.read(guest: false).parts.contains { $0.name == "virtual machine" }
    })
    func aGuestWithNoVirtualMachineFoundLeavesNoTotal() {
        let memory = Memory.read(guest: true)
        #expect(memory.parts.contains { $0.name == "virtual machine" && $0.footprint == nil })
        #expect(memory.total == nil)
    }
}
