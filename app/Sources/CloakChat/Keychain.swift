import CloakControl
import CryptoKit
import Foundation
import Security

/// The conversations' one 256-bit key, stored in Apple's Data Protection
/// Keychain when the app carries an embedded provisioning profile (zero macOS
/// password prompts) with transparent read/mirror fallback to the legacy login
/// keychain for existing installs. Never syncs (`ThisDeviceOnly`).
public enum Keychain {
    static let service = KeychainStore.service("sh.regents.cloak.conversations")

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
        let result = KeychainStore.readData(matching: item, migrationLabel: "Regents Cloak conversations")
        guard result.status != errSecItemNotFound else { return nil }
        guard result.status == errSecSuccess, let data = result.data, data.count == 32 else { throw Failure(status: result.status) }
        return SymmetricKey(data: data)
    }

    /// A new key, stored; never one over a key already there.
    @concurrent
    public static func make() async throws(Failure) -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let status = KeychainStore.addUnique(base: item, label: "Regents Cloak conversations", data: data)
        guard status == errSecSuccess else { throw Failure(status: status) }
        return key
    }
}

/// An owner's API key for a provider, stored in Data Protection Keychain when
/// profiled (with transparent legacy fallback), this device only.
public struct ProviderKeychain: Sendable {
    let service: String
    let account: String
    let label: String

    /// NEAR mode's key from NEAR AI Cloud.
    public static let near = ProviderKeychain(
        service: KeychainStore.service("sh.regents.cloak.near"), account: "near", label: "Regents Cloak NEAR key")
    /// Venice's optional Inference Only API key.
    public static let venice = ProviderKeychain(
        service: KeychainStore.service("sh.regents.cloak.venice"), account: "venice", label: "Regents Cloak Venice key")

    private var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @concurrent
    public func has() async throws(Keychain.Failure) -> Bool {
        let result = KeychainStore.readAttributes(matching: item)
        guard result.status != errSecItemNotFound else { return false }
        guard result.status == errSecSuccess else { throw Keychain.Failure(status: result.status) }
        return true
    }

    public func key() throws(Keychain.Failure) -> String {
        let result = KeychainStore.readData(matching: item, migrationLabel: label)
        guard result.status == errSecSuccess, let data = result.data, let key = String(data: data, encoding: .utf8) else {
            throw Keychain.Failure(status: result.status)
        }
        return key
    }

    @concurrent
    public func store(_ key: String) async throws(Keychain.Failure) {
        let status = KeychainStore.upsert(base: item, label: label, data: Data(key.utf8))
        guard status == errSecSuccess else { throw Keychain.Failure(status: status) }
    }

    @concurrent
    public func remove() async throws(Keychain.Failure) {
        let status = KeychainStore.delete(matching: item)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Keychain.Failure(status: status) }
    }
}
