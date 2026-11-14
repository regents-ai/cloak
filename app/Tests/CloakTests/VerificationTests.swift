import CloakHost
import Foundation
import Testing

@testable import CloakSupervisor

/// The startup check as the guest's console shows it: Running needs the
/// check's rewrite and then the sender ready, and the guest's end after that
/// is seen.
@Suite
struct VerificationTests {
    static let result = #"{"name":"startup","outcome":"rewritten","texts":["Name the three biggest rivers in Europe."],"seconds":0.5}"#

    func write(_ verification: Verification, _ lines: String...) {
        verification.console.fileHandleForWriting.write(Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    @Test func theCheckPassesOnceTheSenderIsReady() async throws {
        let verification = Verification()
        defer { verification.close() }
        write(verification, Self.result, "cloak-guest: check exited 0", "cloak-guest: agent check exited 0",
              "cloak-guest: sender ready")
        _ = try await verification.passed()
        verification.ended(.poweredOff)
        guard case .poweredOff = await verification.end() else {
            Issue.record("the guest's end was not seen")
            return
        }
    }

    @Test func aGuestWhoseSenderDoesNotStartFails() async throws {
        let verification = Verification()
        defer { verification.close() }
        write(verification, Self.result, "cloak-guest: check exited 0", "cloak-guest: agent check exited 0",
              "cloak-guest: sender did not start")
        verification.ended(.poweredOff)
        await #expect(throws: Failure.self) { try await verification.passed() }
    }
}
