Cloak v0.2.4 (Beta) fixes NEAR AI Gateway verification across daily NEAR gateway container rotations and enables fast Sparkle delta updates.

What's new in v0.2.4:
- Resilient NEAR AI Gateway Verification: Updated cloak-near to pin the NEAR gateway on its full Intel TDX hardware, OS image, and dstack KMS identity (MRTD, RTMR0-2, app-id, key-provider, mr-kms, os-image-hash) while verifying MRCONFIGID against app_compose and cross-binding it to Intel Trust Authority's gateway token. Routine daily nearaidev/cloud-api container deployments no longer trigger "Proof refused" while the E2EE v2 model enclave retains strict compose pinning.
- Sparkle Delta Updates: Added EdDSA-signed binary delta updates (LZMA) so existing Cloak users updating from recent builds download only a few megabytes instead of the full ~170 MB DMG (with automatic verified full-DMG fallback).

Beta & Wallet Security Notice: Cloak v0.2 is beta software and has not yet been independently audited. Keep wallet balances small, back up or withdraw funds before wiping or switching Macs (keys never sync to iCloud), and note the 30-day protocol limit on untouched zkAPI deposits. Read the full Wallet Security & Recovery guide at regents.sh/docs/cloak/wallets.

Share feedback at regents.sh/patchbay/cloak, github.com/regents-ai/cloak/issues, or @regents_sh on X.
