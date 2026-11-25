# Security Policy

## Beta & Audit Status

Regents Cloak (`v0.2.x Beta`) is public beta software and has not yet undergone an independent third-party security audit. Treat Cloak wallets as small working balances only and review [docs/wallet-security.md](docs/wallet-security.md) before depositing or transferring crypto.

## Supported Versions

Security fixes are released for the latest signed release on [GitHub Releases](https://github.com/regents-ai/cloak/releases):

| Version | Supported |
| :--- | :--- |
| Latest `0.2.x` | Yes |
| Older releases | No |

## Reporting a Vulnerability

**Please do not report security vulnerabilities in public GitHub issues, pull requests, or forum posts.**

Report vulnerabilities privately through either of these channels:

1. **GitHub Security Advisories (preferred):** Open a private report at [github.com/regents-ai/cloak/security/advisories/new](https://github.com/regents-ai/cloak/security/advisories/new).
2. **Email:** Send details to `build@regents.sh` with `[SECURITY]` in the subject line.

Please include:
- A clear description of the vulnerability and its impact.
- Step-by-step reproduction instructions, proof-of-concept inputs, or affected file/line references.
- Your macOS version and Cloak version/build number.

We aim to acknowledge reports within 48 hours and coordinate disclosure once a fix is verified and released.

## Scope

High-priority security areas include:
- **Network & Tor isolation:** Any path that leaks user prompts, wallet traffic, or DNS outside Tor when Tor routing is active, or allows the guest VM / Pi agent sandbox to bypass Tor.
- **VM & sandbox boundaries:** Escapes from the NIC-less Linux microVM (`guest/`), App-Sandboxed inference workers (`llama-worker/`, `vmlx-worker/`), or `CloakDoor` (`127.0.0.1:8742/v1`).
- **Cryptographic verification & payments:** Flaws in NEAR Intel TDX / NVIDIA GPU attestation or E2EE (`guest/near/`), zkAPI (`guest/pay/`), Boundless/Tempo (`guest/sender/`), Venice x402, or local wallet/chat encryption and Keychain handling (`app/`).
- **Release & update integrity:** Code signing, Sparkle EdDSA update verification, and pinned build/model hash checks (`reference/models.json`, `reference/sources.json`, `reference/near-pins.json`).

## Verifying Releases

Every official Cloak release is Developer ID signed, notarized by Apple (`Team ID: 367G3Z7G3J`), and published with `SHA256SUMS.txt` and `checksums.json` directly on [GitHub Releases](https://github.com/regents-ai/cloak/releases/latest). Verification instructions are available at [regents.sh/cloak/install](https://regents.sh/cloak/install#verify-your-download) and inside the app under **Settings → Verify Release**.
