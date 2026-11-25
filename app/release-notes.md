Cloak v0.2.7 (Beta) adds user-initiated, zero-telemetry Redacted Diagnostic Reports in Settings → Status and Settings → Feedback so beta users can inspect and share local logs and macOS crash traces without any background telemetry.

What's new in v0.2.7:
- Redacted Diagnostic Reports (Zero Telemetry): Open Settings → Status or Settings → Feedback and click "Create Redacted Report…" to generate an inspectable plain-text report on-device containing Cloak release/build, macOS version, CPU/RAM tier, supervisor phase, recent Cloak unified logs, and the newest macOS crash report stack trace (if any). Home usernames, non-loopback IPs, EVM wallet addresses, long hex secrets, Bearer/API keys, and emails are scrubbed automatically, and nothing leaves your Mac unless you copy and share it.
- Local Post-Crash Notice: If macOS recorded a Cloak crash report in the last 7 days, Settings → Status and Settings → Feedback surface a quiet local notice with a one-click "Inspect Report…" button.

Beta & Wallet Security Notice: Cloak v0.2 is beta software and has not yet been independently audited. Keep wallet balances small, back up or withdraw funds before wiping or switching Macs (keys never sync to iCloud), and note the 30-day protocol limit on untouched zkAPI deposits. Read the full Wallet Security & Recovery guide at regents.sh/docs/cloak/wallets.

Share feedback at regents.sh/patchbay/cloak, github.com/regents-ai/cloak/issues, or @regents_sh on X.
