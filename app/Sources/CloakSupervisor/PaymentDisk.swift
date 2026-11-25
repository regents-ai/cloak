import CloakControl
import CloakHost
import CryptoKit
import Foundation
import Security

/// V's payment disk on the Mac (zkAPI step 4): one image file in an
/// owner-only folder of the support folder (`Layout.paymentDisk`), and the
/// 32 random bytes it is encrypted under, kept as the conversations' key is
/// kept (`PaymentDiskKey`). The guest opens the disk with the key, and makes
/// it only in an image whose first 16 MiB are zero: here, a blank image is a
/// new disk. The Mac holds the disk's key and no payment secret; what is on
/// the disk is the guest's payer's alone (guest/image/pay-disk).
enum PaymentDisk {
    /// The image's size. It is sparse, so it takes on the Mac only what the
    /// guest has written.
    static let size: off_t = 1 << 30
    /// Where LUKS2 keeps both copies of its header and its keyslots, which
    /// are zero in a blank image.
    static let header = 16 << 20

    /// The disk for this run: the image, made blank when there is none, and
    /// its key, made when there is none and the image is blank. A missing
    /// key for an image that holds a disk is a failure, and nothing is
    /// changed: a new key would never open it.
    @concurrent
    static func attach(_ image: URL) async throws(Failure) -> Guest.PaymentDisk {
        let blank: Bool
        do {
            try Places.makeOwnerOnly(image.deletingLastPathComponent())
            blank = try made(image)
        } catch {
            throw Failure(.guestFailed, "cannot make the payment disk's image: \(error)")
        }
        let key: Data
        do {
            if let found = try await PaymentDiskKey.find() {
                key = found
            } else if blank {
                key = try await PaymentDiskKey.make()
            } else {
                throw Failure(.guestFailed, "the payment disk's key is not in the keychain, and its image holds a disk")
            }
            return try Guest.PaymentDisk(image: image, key: key, isNew: blank)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(.guestFailed, "cannot read the payment disk's key: \(error)")
        }
    }

    /// Makes the image, owner-only and sparse, when there is none. Returns
    /// whether it is blank.
    private static func made(_ image: URL) throws -> Bool {
        let file = open(image.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        if info.st_size == 0 {
            guard ftruncate(file, size) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return true
        }
        var start = [UInt8](repeating: 0, count: header)
        let read = pread(file, &start, header, 0)
        guard read >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return start[..<read].allSatisfy { $0 == 0 }
    }
}

/// The payment disk's key: 32 random bytes, a generic password in the login
/// keychain, this device only, kept as the conversations' key is
/// (`Keychain` in CloakChat, whose note says why it is the file keychain).
/// Each call can wait on the keychain's question to its owner, so none is
/// made on the main thread.
enum PaymentDiskKey {
    static let service = KeychainStore.service("sh.regents.cloak.paydisk")

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "keychain status \(status)" }
    }

    private static var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "payment disk",
        ]
    }

    /// The key, or nil when there is none.
    @concurrent
    static func find() async throws(Failure) -> Data? {
        let result = KeychainStore.readData(matching: item, migrationLabel: "Regents Cloak payment disk")
        guard result.status != errSecItemNotFound else { return nil }
        guard result.status == errSecSuccess, let data = result.data, data.count == 32 else { throw Failure(status: result.status) }
        return data
    }

    /// A new key, stored; never one over a key already there.
    @concurrent
    static func make() async throws(Failure) -> Data {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let status = KeychainStore.addUnique(base: item, label: "Regents Cloak payment disk", data: key)
        guard status == errSecSuccess else { throw Failure(status: status) }
        return key
    }
}
