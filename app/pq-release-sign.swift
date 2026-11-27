#!/usr/bin/env swift
// Post-quantum release key management and signing for Regents Cloak (FIPS 204 ML-DSA-65).
// Uses native Apple CryptoKit (macOS 26+) and stores the 32-byte private seed exclusively
// in the macOS login Keychain (never written to disk or git).
//
// Usage:
//   swift app/pq-release-sign.swift keygen
//   swift app/pq-release-sign.swift public-key
//   swift app/pq-release-sign.swift sign <input-file> <output-sig-file>
//   swift app/pq-release-sign.swift verify <input-file> <sig-file> <public-key-base64>

import CryptoKit
import Foundation
import Security

let service = "sh.regents.cloak.pq-release-key"
let account = "cloak-mldsa65"
let domainPrefix = Data("regents-cloak-release-mldsa65-v1\n".utf8)

func die(_ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(1)
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func loadSeedFromKeychain() -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return data
}

func saveSeedToKeychain(_ seed: Data) {
    let attrs: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrLabel as String: "Regents Cloak ML-DSA-65 Release Signing Key",
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        kSecValueData as String: seed,
    ]
    let status = SecItemAdd(attrs as CFDictionary, nil)
    guard status == errSecSuccess else {
        die("Keychain save failed with OSStatus \(status)")
    }
}

func framed(_ payload: Data) -> Data {
    var out = Data(capacity: domainPrefix.count + payload.count)
    out.append(domainPrefix)
    out.append(payload)
    return out
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    die("usage: pq-release-sign.swift <keygen|public-key|sign|verify> ...")
}

switch cmd {
case "keygen":
    if loadSeedFromKeychain() != nil {
        die("An ML-DSA-65 key already exists in Keychain (\(service)/\(account)). Refusing to overwrite.")
    }
    do {
        let priv = try MLDSA65.PrivateKey()
        saveSeedToKeychain(Data(priv.seedRepresentation))
        let pub = Data(priv.publicKey.rawRepresentation)
        print("Stored ML-DSA-65 private seed in macOS Keychain (\(service)/\(account)).")
        print("Public key fingerprint (SHA-256): \(sha256Hex(pub))")
        print("Set app/release.json \"pq_release_public_key\" to:")
        print(pub.base64EncodedString())
    } catch {
        die("keygen failed: \(error)")
    }

case "public-key":
    guard let seed = loadSeedFromKeychain() else {
        die("No ML-DSA-65 key found in Keychain (\(service)/\(account)). Run `keygen` first.")
    }
    do {
        let priv = try MLDSA65.PrivateKey(seedRepresentation: seed, publicKey: nil)
        print(Data(priv.publicKey.rawRepresentation).base64EncodedString())
    } catch {
        die("public-key failed: \(error)")
    }

case "sign":
    guard args.count == 3 else { die("usage: pq-release-sign.swift sign <input-file> <output-sig-file>") }
    guard let seed = loadSeedFromKeychain() else {
        die("No ML-DSA-65 key found in Keychain (\(service)/\(account)). Run `keygen` first.")
    }
    do {
        let payload = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let priv = try MLDSA65.PrivateKey(seedRepresentation: seed, publicKey: nil)
        let sig = try priv.signature(for: framed(payload))
        try (sig.base64EncodedString() + "\n").write(toFile: args[2], atomically: true, encoding: .utf8)
        print("Signed \(args[1]) -> \(args[2]) (ML-DSA-65, \(sig.count) bytes)")
    } catch {
        die("sign failed: \(error)")
    }

case "verify":
    guard args.count == 4 else {
        die("usage: pq-release-sign.swift verify <input-file> <sig-file> <public-key-base64>")
    }
    do {
        let payload = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let sigB64 = try String(contentsOfFile: args[2], encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pubB64 = args[3].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sig = Data(base64Encoded: sigB64), let pubData = Data(base64Encoded: pubB64) else {
            die("Invalid base64 in signature or public key.")
        }
        let pub = try MLDSA65.PublicKey(rawRepresentation: pubData)
        guard pub.isValidSignature(sig, for: framed(payload)) else {
            die("ML-DSA-65 signature verification FAILED for \(args[1]).")
        }
        print("Verified ML-DSA-65 signature for \(args[1]) (key SHA-256: \(sha256Hex(pubData))).")
    } catch {
        die("verify failed: \(error)")
    }

default:
    die("unknown subcommand: \(cmd)")
}
