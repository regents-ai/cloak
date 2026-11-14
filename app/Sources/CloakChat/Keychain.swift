import CryptoKit
import Foundation
import Security

/// The conversations' one 256-bit key, a generic password in the login
/// keychain, this device only. The data protection keychain needs a signed
/// app with a keychain group, which this ad-hoc build is not (it answers
/// errSecMissingEntitlement), so the item is in the file keychain, which
/// never syncs, and which asks before an app it does not know reads it: a
/// rebuilt app is one it does not know. Each call can wait on that question,
/// so none is made on the main thread.
public enum Keychain {
    static let service = "sh.regents.cloak.conversations"

    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "keychain status \(status)" }
    }

    private static var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "conversations",
        ]
    }

    /// The key, or nil when there is none.
    @concurrent
    public static func find() async throws(Failure) -> SymmetricKey? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { throw Failure(status: status) }
        return SymmetricKey(data: data)
    }

    /// A new key, stored; never one over a key already there.
    @concurrent
    public static func make() async throws(Failure) -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        var query = item
        query[kSecAttrLabel as String] = "Regents Cloak conversations"
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
        return key
    }
}
