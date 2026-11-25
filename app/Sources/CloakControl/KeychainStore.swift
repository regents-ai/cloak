import Foundation
import Security

/// Shared macOS Keychain access layer used by all 6 Cloak secrets
/// (`conversations`, `paydisk`, `wallet`, `venice-wallet`, `near`, `venice`).
///
/// When the app bundle carries `Contents/embedded.provisionprofile` (signed
/// with `keychain-access-groups` for Team `367G3Z7G3J`), items are stored in
/// Apple's modern **Data Protection Keychain** (`kSecUseDataProtectionKeychain`),
/// which authorizes access cryptographically by Team ID and eliminates macOS
/// login-keychain password prompts across rebuilds and updates.
///
/// Safety invariants:
/// - Reads check Data Protection first, then fall back to the legacy file-based
///   login keychain so existing wallets, chats, and payment disks remain
///   accessible across upgrades.
/// - Successful legacy data reads copy a backup into Data Protection without
///   deleting the legacy item (never destructive for wallets or encryption keys).
/// - Unique inserts (`addUnique`) check both keychains first and refuse
///   duplicates so a second wallet or disk key can never be created beside an
///   existing one.
public enum KeychainStore {
    public static let accessGroup = "367G3Z7G3J.sh.regents.cloak"

    /// Returns the isolated Keychain service identifier for the active app
    /// flavor so `Cloak Dev.app` (`*.dev`) never touches production secrets.
    public static func service(_ base: String, isDev: Bool = Places.isDev) -> String {
        isDev ? "\(base).dev" : base
    }

    /// True when the running `.app` bundle carries an embedded provisioning
    /// profile authorizing Data Protection Keychain access (production only).
    public static var usesDataProtection: Bool {
        guard !Places.isDev else { return false }
        return FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL.appending(path: "Contents/embedded.provisionprofile").path
        )
    }

    public static func dataProtectionQuery(_ base: [String: Any]) -> [String: Any] {
        var q = base
        q[kSecUseDataProtectionKeychain as String] = true
        q[kSecAttrAccessGroup as String] = accessGroup
        return q
    }

    /// Reads raw secret bytes for `base` (must contain `kSecClass` and
    /// `kSecAttrService`, plus optional `kSecAttrAccount`).
    /// When `usesDataProtection` is true and the item is found only in the
    /// legacy login keychain, silently mirrors it into Data Protection (keeping
    /// the legacy item intact) so future reads require zero prompts.
    public static func readData(
        matching base: [String: Any],
        migrationLabel: String? = nil,
        dataProtection: Bool = usesDataProtection
    ) -> (status: OSStatus, data: Data?) {
        if dataProtection {
            var dp = dataProtectionQuery(base)
            dp[kSecReturnData as String] = true
            dp[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(dp as CFDictionary, &result)
            if status == errSecSuccess {
                return (errSecSuccess, result as? Data)
            }
            if status != errSecItemNotFound && status != errSecMissingEntitlement {
                return (status, nil)
            }
        }

        var legacy = base
        legacy[kSecReturnData as String] = true
        legacy[kSecMatchLimit as String] = kSecMatchLimitOne
        if dataProtection {
            // Also fetch account attribute so wallet items (whose account is
            // the 0x address) can be mirrored faithfully into Data Protection.
            legacy[kSecReturnAttributes as String] = true
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(legacy as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }

        if dataProtection, let dict = result as? [String: Any], let data = dict[kSecValueData as String] as? Data {
            var add = dataProtectionQuery(base)
            if add[kSecAttrAccount as String] == nil, let account = dict[kSecAttrAccount as String] as? String {
                add[kSecAttrAccount as String] = account
            }
            if let label = migrationLabel ?? (dict[kSecAttrLabel as String] as? String) {
                add[kSecAttrLabel as String] = label
            }
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecValueData as String] = data
            _ = SecItemAdd(add as CFDictionary, nil)
            return (errSecSuccess, data)
        }

        if let data = result as? Data {
            return (errSecSuccess, data)
        }
        if let dict = result as? [String: Any], let data = dict[kSecValueData as String] as? Data {
            return (errSecSuccess, data)
        }
        return (errSecDecode, nil)
    }

    /// Reads item attributes without touching secret bytes (never triggers a
    /// data-read prompt on login keychain items).
    public static func readAttributes(
        matching base: [String: Any],
        dataProtection: Bool = usesDataProtection
    ) -> (status: OSStatus, attributes: [String: Any]?) {
        if dataProtection {
            var dp = dataProtectionQuery(base)
            dp[kSecReturnAttributes as String] = true
            dp[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(dp as CFDictionary, &result)
            if status == errSecSuccess {
                return (errSecSuccess, result as? [String: Any])
            }
            if status != errSecItemNotFound && status != errSecMissingEntitlement {
                return (status, nil)
            }
        }

        var legacy = base
        legacy[kSecReturnAttributes as String] = true
        legacy[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(legacy as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        return (errSecSuccess, result as? [String: Any])
    }

    /// Adds a non-replaceable secret (`conversations`, `paydisk`, `wallet`,
    /// `venice-wallet`). Refuses to add if an item already exists in either
    /// Data Protection or the legacy login keychain.
    public static func addUnique(
        base: [String: Any],
        label: String,
        data: Data,
        dataProtection: Bool = usesDataProtection
    ) -> OSStatus {
        let existing = readAttributes(matching: base, dataProtection: dataProtection)
        if existing.status == errSecSuccess {
            return errSecDuplicateItem
        }
        if existing.status != errSecItemNotFound {
            return existing.status
        }

        if dataProtection {
            var dp = dataProtectionQuery(base)
            dp[kSecAttrLabel as String] = label
            dp[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            dp[kSecValueData as String] = data
            let status = SecItemAdd(dp as CFDictionary, nil)
            if status != errSecMissingEntitlement {
                return status
            }
        }

        var legacy = base
        legacy[kSecAttrLabel as String] = label
        legacy[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        legacy[kSecValueData as String] = data
        return SecItemAdd(legacy as CFDictionary, nil)
    }

    /// Stores or replaces a replaceable API key (`near`, `venice`).
    public static func upsert(
        base: [String: Any],
        label: String,
        data: Data,
        dataProtection: Bool = usesDataProtection
    ) -> OSStatus {
        if dataProtection {
            let dpBase = dataProtectionQuery(base)
            var dpAdd = dpBase
            dpAdd[kSecAttrLabel as String] = label
            dpAdd[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            dpAdd[kSecValueData as String] = data
            let status = SecItemAdd(dpAdd as CFDictionary, nil)
            if status == errSecDuplicateItem {
                return SecItemUpdate(dpBase as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            }
            if status != errSecMissingEntitlement {
                return status
            }
        }

        var legacyAdd = base
        legacyAdd[kSecAttrLabel as String] = label
        legacyAdd[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        legacyAdd[kSecValueData as String] = data
        let status = SecItemAdd(legacyAdd as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        return status
    }

    /// Deletes a replaceable API key (`near`, `venice`) from both Data
    /// Protection and the legacy login keychain so Remove leaves no stale copy.
    public static func delete(
        matching base: [String: Any],
        dataProtection: Bool = usesDataProtection
    ) -> OSStatus {
        var dpStatus: OSStatus = errSecItemNotFound
        if dataProtection {
            dpStatus = SecItemDelete(dataProtectionQuery(base) as CFDictionary)
            if dpStatus != errSecSuccess && dpStatus != errSecItemNotFound && dpStatus != errSecMissingEntitlement {
                return dpStatus
            }
        }
        let legacyStatus = SecItemDelete(base as CFDictionary)
        if legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound {
            return errSecSuccess
        }
        return dpStatus == errSecSuccess ? errSecSuccess : legacyStatus
    }
}
