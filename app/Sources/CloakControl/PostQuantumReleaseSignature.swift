import CryptoKit
import Foundation

/// Post-quantum release co-signature verification and signing for Regents Cloak
/// using native Apple CryptoKit FIPS 204 `ML-DSA-65` (macOS 26+).
///
/// Signatures cover a fixed domain separator followed by the exact bytes of the
/// release manifest (`checksums.json` or `SHA256SUMS.txt`). This installs a
/// post-quantum update trust anchor alongside Sparkle's Ed25519 key and Apple
/// Developer ID notarization while classical trust roots remain intact.
public enum PostQuantumReleaseSignature {
    public static let algorithmName = "ML-DSA-65"
    public static let domainPrefix = Data("regents-cloak-release-mldsa65-v1\n".utf8)
    public static let seedByteCount = 32
    public static let publicKeyByteCount = 1952
    public static let signatureByteCount = 3309

    public enum ArtifactKind: String, Codable, Equatable, Sendable {
        case dmg
        case appBinary = "app_binary"
    }

    public enum VerificationError: Error, Equatable, LocalizedError, Sendable {
        case invalidBase64(String)
        case invalidKeyLength(expected: Int, actual: Int)
        case invalidSignatureLength(expected: Int, actual: Int)
        case signatureVerificationFailed
        case invalidChecksumsJSON(String)
        case artifactDigestMismatch(expected: String, actual: String)
        case unreadableFile(String)

        public var errorDescription: String? {
            switch self {
            case .invalidBase64(let label):
                "Invalid base64 encoding for \(label)."
            case .invalidKeyLength(let expected, let actual):
                "Invalid ML-DSA-65 key length: expected \(expected) bytes, got \(actual)."
            case .invalidSignatureLength(let expected, let actual):
                "Invalid ML-DSA-65 signature length: expected \(expected) bytes, got \(actual)."
            case .signatureVerificationFailed:
                "ML-DSA-65 signature did not verify against the pinned release public key."
            case .invalidChecksumsJSON(let detail):
                "Malformed checksums.json: \(detail)"
            case .artifactDigestMismatch(let expected, let actual):
                "Artifact SHA-256 mismatch: expected \(expected), got \(actual)."
            case .unreadableFile(let path):
                "Could not read file at \(path)."
            }
        }
    }

    public struct Keypair: Equatable, Sendable {
        public let seedBase64: String
        public let publicKeyBase64: String
        public let keyFingerprintSHA256: String
    }

    public struct ReleaseChecksums: Codable, Equatable, Sendable {
        public let tag: String
        public let release: String
        public let build: String
        public let dmgFilename: String
        public let dmgSHA256: String
        public let appBinarySHA256: String
        public let cdhash: String
        public let cdhashFull: String?
        public let teamID: String

        enum CodingKeys: String, CodingKey {
            case tag, release, build, cdhash
            case dmgFilename = "dmg_filename"
            case dmgSHA256 = "dmg_sha256"
            case appBinarySHA256 = "app_binary_sha256"
            case cdhashFull = "cdhash_full"
            case teamID = "team_id"
        }
    }

    public struct VerificationOutcome: Codable, Equatable, Sendable {
        public let algorithm: String
        public let keyFingerprintSHA256: String
        public let signatureValid: Bool
        public let tag: String
        public let release: String
        public let build: String
        public let teamID: String
        public let artifactChecked: Bool
        public let artifactKind: ArtifactKind?
        public let artifactSHA256: String?
        public let artifactMatchesChecksums: Bool?
        public let verified: Bool
    }

    /// Generates a fresh FIPS 204 ML-DSA-65 keypair using CryptoKit.
    public static func generateKeypair() throws -> Keypair {
        let priv = try MLDSA65.PrivateKey()
        let seed = Data(priv.seedRepresentation)
        let pub = Data(priv.publicKey.rawRepresentation)
        return Keypair(
            seedBase64: seed.base64EncodedString(),
            publicKeyBase64: pub.base64EncodedString(),
            keyFingerprintSHA256: sha256Hex(pub)
        )
    }

    /// Computes the SHA-256 hex fingerprint of a base64-encoded raw ML-DSA-65 public key.
    public static func publicKeyFingerprint(publicKeyBase64: String) throws -> String {
        let raw = try decodePublicKeyData(publicKeyBase64)
        return sha256Hex(raw)
    }

    /// Produces a domain-separated base64 ML-DSA-65 signature over `payload`.
    public static func sign(payload: Data, seedBase64: String) throws -> String {
        let trimmed = seedBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seed = Data(base64Encoded: trimmed) else {
            throw VerificationError.invalidBase64("ML-DSA-65 seed")
        }
        guard seed.count == seedByteCount else {
            throw VerificationError.invalidKeyLength(expected: seedByteCount, actual: seed.count)
        }
        let priv = try MLDSA65.PrivateKey(seedRepresentation: seed, publicKey: nil)
        let signature = try priv.signature(for: framed(payload))
        return signature.base64EncodedString()
    }

    /// Verifies a domain-separated base64 ML-DSA-65 signature over `payload`.
    public static func verify(payload: Data, signatureBase64: String, publicKeyBase64: String) throws -> Bool {
        let pubData = try decodePublicKeyData(publicKeyBase64)
        let sigData = try decodeSignatureData(signatureBase64)
        let pub = try MLDSA65.PublicKey(rawRepresentation: pubData)
        return pub.isValidSignature(sigData, for: framed(payload))
    }

    /// Verifies a signed `checksums.json` payload and optionally checks a local DMG or app binary
    /// against the authenticated SHA-256 inside `checksums.json`. Fails closed on any error.
    public static func verifyRelease(
        checksumsData: Data,
        signatureBase64: String,
        publicKeyBase64: String,
        artifactURL: URL? = nil,
        artifactKind: ArtifactKind = .dmg
    ) throws -> VerificationOutcome {
        let fingerprint = try publicKeyFingerprint(publicKeyBase64: publicKeyBase64)
        let validSig = try verify(
            payload: checksumsData,
            signatureBase64: signatureBase64,
            publicKeyBase64: publicKeyBase64
        )
        guard validSig else {
            throw VerificationError.signatureVerificationFailed
        }

        let checksums: ReleaseChecksums
        do {
            checksums = try JSONDecoder().decode(ReleaseChecksums.self, from: checksumsData)
        } catch {
            throw VerificationError.invalidChecksumsJSON(error.localizedDescription)
        }

        if let artifactURL {
            guard let actualSHA = sha256Hex(ofFileAt: artifactURL) else {
                throw VerificationError.unreadableFile(artifactURL.path)
            }
            let expectedSHA: String = switch artifactKind {
            case .dmg: checksums.dmgSHA256.lowercased()
            case .appBinary: checksums.appBinarySHA256.lowercased()
            }
            guard actualSHA.lowercased() == expectedSHA else {
                throw VerificationError.artifactDigestMismatch(expected: expectedSHA, actual: actualSHA)
            }
            return VerificationOutcome(
                algorithm: algorithmName,
                keyFingerprintSHA256: fingerprint,
                signatureValid: true,
                tag: checksums.tag,
                release: checksums.release,
                build: checksums.build,
                teamID: checksums.teamID,
                artifactChecked: true,
                artifactKind: artifactKind,
                artifactSHA256: actualSHA,
                artifactMatchesChecksums: true,
                verified: true
            )
        }

        return VerificationOutcome(
            algorithm: algorithmName,
            keyFingerprintSHA256: fingerprint,
            signatureValid: true,
            tag: checksums.tag,
            release: checksums.release,
            build: checksums.build,
            teamID: checksums.teamID,
            artifactChecked: false,
            artifactKind: nil,
            artifactSHA256: nil,
            artifactMatchesChecksums: nil,
            verified: true
        )
    }

    /// Streams SHA-256 hex digest of a file in 1 MiB chunks.
    public static func sha256Hex(ofFileAt fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func framed(_ payload: Data) -> Data {
        var data = Data(capacity: domainPrefix.count + payload.count)
        data.append(domainPrefix)
        data.append(payload)
        return data
    }

    private static func decodePublicKeyData(_ base64: String) throws -> Data {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else {
            throw VerificationError.invalidBase64("ML-DSA-65 public key")
        }
        guard data.count == publicKeyByteCount else {
            throw VerificationError.invalidKeyLength(expected: publicKeyByteCount, actual: data.count)
        }
        return data
    }

    private static func decodeSignatureData(_ base64: String) throws -> Data {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else {
            throw VerificationError.invalidBase64("ML-DSA-65 signature")
        }
        guard data.count == signatureByteCount else {
            throw VerificationError.invalidSignatureLength(expected: signatureByteCount, actual: data.count)
        }
        return data
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
