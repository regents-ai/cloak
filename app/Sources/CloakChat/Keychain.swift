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

/// An owner's key for a provider: a generic password in the login keychain,
/// this device only, in the file keychain as the conversations' key is
/// (`Keychain`). Read only as a request that uses it is built, and given to
/// that request alone. Each has a service of its own, never renamed.
public struct ProviderKeychain: Sendable {
    let service: String
    let account: String
    let label: String

    /// NEAR mode's: the owner's key from NEAR AI Cloud.
    public static let near = ProviderKeychain(service: "sh.regents.cloak.near", account: "near", label: "Regents Cloak NEAR key")
    /// Venice's: the owner's Inference Only key from Venice.
    public static let venice = ProviderKeychain(service: "sh.regents.cloak.venice", account: "venice", label: "Regents Cloak Venice key")

    private var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Whether a key is kept; reads its attributes only, never the key.
    @concurrent
    public func has() async throws(Keychain.Failure) -> Bool {
        var query = item
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return false }
        guard status == errSecSuccess else { throw Keychain.Failure(status: status) }
        return true
    }

    /// The key. Blocking: called while a request is built, off the main
    /// thread.
    public func key() throws(Keychain.Failure) -> String {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw Keychain.Failure(status: status)
        }
        return key
    }

    /// Keeps `key` in place of any key kept before.
    @concurrent
    public func store(_ key: String) async throws(Keychain.Failure) {
        var query = item
        query[kSecAttrLabel as String] = label
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = Data(key.utf8)
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Keychain.Failure(status: status) }
    }

    /// Removes the key; none kept is no failure.
    @concurrent
    public func remove() async throws(Keychain.Failure) {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Keychain.Failure(status: status) }
    }
}
