@testable import CloakChat
import Security
import Testing

/// Whether this Mac holds the wallet, as the keychain's answers move it. The
/// answers are given here; the keychain is never asked.
struct WalletPresenceTests {
    /// A read that fails is a stage of its own, which the wallet's sheet
    /// offers to read again; the next read moves it on as any read does.
    @Test func aReadThatFailsIsUnreadableUntilAReadWorks() {
        var presence = WalletPresence(.failure(Keychain.Failure(status: errSecInteractionNotAllowed)))
        #expect(presence == .unreadable)
        #expect(presence.address == nil)
        presence = WalletPresence(.success("0x01"))
        #expect(presence == .held(address: "0x01"))
        #expect(presence.address == "0x01")
        #expect(WalletPresence(.success(nil)) == .absent)
    }

    @Test func createStartsWhereThereIsNoWallet() {
        var presence = WalletPresence.absent
        let started = presence.create()
        #expect(started)
        #expect(presence == .creating)
    }

    /// Never over a wallet, never while the keychain is unread or could not
    /// be read, and never twice at once.
    @Test(arguments: [WalletPresence.looking, .unreadable, .creating, .held(address: "0x01")])
    func createStartsNowhereElse(_ start: WalletPresence) {
        var presence = start
        let started = presence.create()
        #expect(!started)
        #expect(presence == start)
    }
}
