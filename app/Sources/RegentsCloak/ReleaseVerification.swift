import CloakControl
import CryptoKit
import Foundation
import Security

/// Live on-disk cryptographic identity of the running Cloak app bundle:
/// its Mach-O executable SHA-256, Apple Code Directory hash (`CDHash`),
/// Developer ID Team Identifier, and pinned FIPS 204 ML-DSA-65 post-quantum
/// release key fingerprint, plus copy-paste macOS Terminal commands so users
/// can independently verify the build using built-in OS tools (`shasum`,
/// `codesign`, `spctl`, and `cloak verify-release`) rather than trusting the
/// app to attest to itself.
struct ReleaseVerification: Equatable, Sendable {
    static let expectedTeamID = "367G3Z7G3J"
    static let githubReleasesURL = URL(string: "https://github.com/regents-ai/cloak/releases")!
    static let websiteInstallURL = URL(string: "https://regents.sh/cloak/install")!

    let releaseVersion: String
    let buildNumber: String
    let appPath: String
    let binarySHA256: String?
    let cdHash: String?
    let teamID: String?
    let pqPublicKeyFingerprint: String?

    var releaseTag: String {
        "\(releaseVersion)-\(buildNumber)"
    }

    var quotedAppPath: String {
        "\"\(appPath)\""
    }

    var quotedBinaryPath: String {
        "\"\(appPath)/Contents/MacOS/RegentsCloak\""
    }

    var quotedCLIPath: String {
        "\"\(appPath)/Contents/MacOS/cloak\""
    }

    /// Built-in macOS Terminal commands users can run independently to verify
    /// this installation and the downloaded DMG against GitHub Releases and
    /// regents.sh/cloak/install.
    var verificationCommands: [(label: String, command: String)] {
        [
            ("Installed app SHA-256 (shasum)", "shasum -a 256 \(quotedBinaryPath)"),
            ("Downloaded DMG SHA-256 (shasum)", "shasum -a 256 ~/Downloads/Regents-Cloak.dmg"),
            ("Apple signature & CDHash (codesign)", "codesign -dvv --strict \(quotedAppPath)"),
            ("Notarization & Gatekeeper (spctl)", "spctl --assess --type execute -vv \(quotedAppPath)"),
            (
                "Post-quantum release signature (ML-DSA-65)",
                "\(quotedCLIPath) verify-release --checksums ~/Downloads/checksums.json --signature ~/Downloads/checksums.json.mldsa65.sig --dmg ~/Downloads/Regents-Cloak.dmg"
            ),
        ]
    }

    /// Computes SHA-256 hex digest of any file using streaming 1 MiB chunks.
    static func sha256Hex(of fileURL: URL) -> String? {
        PostQuantumReleaseSignature.sha256Hex(ofFileAt: fileURL)
    }

    /// Inspects the running `Bundle.main` off the main actor.
    @concurrent static func inspectCurrentBundle() async -> ReleaseVerification {
        let info = Bundle.main.infoDictionary
        let release = (info?["CFBundleShortVersionString"] as? String) ?? "0.2.1"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        let appPath = Bundle.main.bundlePath
        let binarySHA256 = Bundle.main.executableURL.flatMap { sha256Hex(of: $0) }
        let (cdHash, teamID) = readSigningInfo()
        let pqKey = (info?["RegentsPQReleasePublicKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pqFingerprint = pqKey.flatMap { key in
            key.isEmpty ? nil : try? PostQuantumReleaseSignature.publicKeyFingerprint(publicKeyBase64: key)
        }
        return ReleaseVerification(
            releaseVersion: release,
            buildNumber: build,
            appPath: appPath,
            binarySHA256: binarySHA256,
            cdHash: cdHash,
            teamID: teamID,
            pqPublicKeyFingerprint: pqFingerprint
        )
    }

    private static func readSigningInfo() -> (cdHash: String?, teamID: String?) {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return (nil, nil) }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return (nil, nil) }
        var cfInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &cfInfo) == errSecSuccess,
            let dict = cfInfo as? [String: Any]
        else { return (nil, nil) }
        let cdHash = (dict[kSecCodeInfoUnique as String] as? Data)?
            .map { String(format: "%02x", $0) }
            .joined()
        let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        return (cdHash, teamID)
    }
}
