import CloakControl
import Foundation
import Testing

@Suite("Post-Quantum ML-DSA-65 Release Signature")
struct PostQuantumReleaseSignatureTests {
    private static func sampleChecksumsJSON(dmgSHA: String, binSHA: String) -> Data {
        Data(
            """
            {
              "tag": "0.2.8-306",
              "release": "0.2.8",
              "build": "306",
              "dmg_filename": "Regents-Cloak-0.2.8-306.dmg",
              "dmg_sha256": "\(dmgSHA)",
              "app_binary_sha256": "\(binSHA)",
              "cdhash": "deadbeef",
              "team_id": "367G3Z7G3J"
            }
            """.utf8
        )
    }

    @Test("ML-DSA-65 sign and verify roundtrip accepts authentic release and rejects tampering")
    func signVerifyAndRejectTamper() throws {
        let kp = try PostQuantumReleaseSignature.generateKeypair()
        let other = try PostQuantumReleaseSignature.generateKeypair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dmgURL = tmp.appendingPathComponent("Regents-Cloak.dmg")
        try Data("authentic-dmg-bytes".utf8).write(to: dmgURL)
        let dmgSHA = try #require(PostQuantumReleaseSignature.sha256Hex(ofFileAt: dmgURL))
        let checksumsData = Self.sampleChecksumsJSON(dmgSHA: dmgSHA, binSHA: String(repeating: "a", count: 64))

        let sig = try PostQuantumReleaseSignature.sign(payload: checksumsData, seedBase64: kp.seedBase64)

        let ok = try PostQuantumReleaseSignature.verifyRelease(
            checksumsData: checksumsData,
            signatureBase64: sig,
            publicKeyBase64: kp.publicKeyBase64,
            artifactURL: dmgURL,
            artifactKind: .dmg
        )
        #expect(ok.verified)
        #expect(ok.algorithm == "ML-DSA-65")
        #expect(ok.keyFingerprintSHA256 == kp.keyFingerprintSHA256)
        #expect(ok.artifactMatchesChecksums == true)

        // Wrong public key fails closed.
        #expect(throws: PostQuantumReleaseSignature.VerificationError.signatureVerificationFailed) {
            try PostQuantumReleaseSignature.verifyRelease(
                checksumsData: checksumsData,
                signatureBase64: sig,
                publicKeyBase64: other.publicKeyBase64
            )
        }

        // Tampered manifest bytes fail closed.
        var tampered = checksumsData
        tampered.append(UInt8(ascii: " "))
        #expect(throws: PostQuantumReleaseSignature.VerificationError.signatureVerificationFailed) {
            try PostQuantumReleaseSignature.verifyRelease(
                checksumsData: tampered,
                signatureBase64: sig,
                publicKeyBase64: kp.publicKeyBase64
            )
        }

        // Tampered DMG file fails closed even when manifest signature is valid.
        try Data("tampered-dmg-bytes".utf8).write(to: dmgURL)
        #expect {
            try PostQuantumReleaseSignature.verifyRelease(
                checksumsData: checksumsData,
                signatureBase64: sig,
                publicKeyBase64: kp.publicKeyBase64,
                artifactURL: dmgURL,
                artifactKind: .dmg
            )
        } throws: { error in
            if case PostQuantumReleaseSignature.VerificationError.artifactDigestMismatch = error {
                return true
            }
            return false
        }
    }
}
