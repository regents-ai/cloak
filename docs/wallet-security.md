# Cloak Wallet Security, Recovery & 30-Day zkAPI Limit

> **Beta software (`v0.2.0 Beta`):** Cloak is public beta software and has not yet undergone an independent security audit. Treat Cloak wallets as **small working balances only** (e.g., $5–$20), not long-term storage.

Cloak never creates a Regents account and never holds custody of your keys or funds. Every crypto payment rail in Cloak generates a local key on your Mac, isolated per rail, and **never synced to iCloud**.

## How Cloak stores each wallet

| Mode & Rail | Asset & Chain | Where the key lives | Backup / Export |
| --- | --- | --- | --- |
| **Token Inference · Venice** | `USDC` on **Base** | macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synced to iCloud) | **Export Private Key…** in Funds or **Settings → Wallets** (Touch ID / Mac password) |
| **Token Inference · Boundless** | `USDC.e` on **Tempo** | Separate macOS Keychain item (isolated from Venice, never synced to iCloud) | **Export Private Key…** in Funds or **Settings → Wallets** (Touch ID / Mac password) |
| **zkAPI Anon Inference** | `ETH` on **Ethereum Mainnet** | Local AES-GCM encrypted payment disk inside `~/Library/Application Support/RegentsCloak/` sealed by a device-only macOS Keychain key (never synced to iCloud) | No standalone seed export — withdraw active deposits and use **Transfer…** to move ETH out to an external wallet |
| **NEAR AI Gateway** | NEAR AI Cloud API key | macOS Keychain (device-only) | Managed in your [NEAR AI Cloud](https://cloud.near.ai) dashboard |

## What happens if you do not have a backup (Failure modes)

Because Regents never sees or backs up your keys, **loss of local key material is permanent and unrecoverable**:

1. **Wiping macOS, erasing the disk, or losing/breaking your Mac**
   - **Without a backup:** Any ETH left in your zkAPI wallet, any active zkAPI deposit, any Base `USDC` in your Venice wallet, and any Tempo `USDC.e` in your Boundless wallet or open MPP channel are **permanently lost**.
   - **With a backup:** For Venice (Base) and Boundless (Tempo), importing your exported hex private key into any standard EVM wallet recovers the address's on-chain balance. For zkAPI, withdraw your active deposit and transfer ETH out *before* wiping or switching Macs.
2. **Deleting Keychain items or `~/Library/Application Support/RegentsCloak/`**
   - Removing `Cloak.app` from `/Applications` and reinstalling or updating Cloak **keeps** your wallets and chats intact.
   - Manually wiping Cloak's macOS Keychain entries or `~/Library/Application Support/RegentsCloak/` destroys the local keys and encrypted zkAPI payment disk — any remaining funds are **permanently lost** unless you exported the private key (Venice/Boundless) or withdrew funds first.
3. **Sending the wrong asset or wrong network**
   - Each address accepts **one exact asset on one exact chain**:
     - Venice: **Base `USDC` only**
     - Boundless: **Tempo `USDC.e` only**
     - zkAPI: **Ethereum Mainnet `ETH` only**
   - Sending any other token or using the wrong chain (for example, sending Arbitrum ETH to the zkAPI address, or Base ETH instead of Base USDC to the Venice address) puts those funds outside Cloak's reach. For Venice and Boundless, you may be able to recover mis-sent EVM assets by exporting the private key into an external wallet; for zkAPI, there is no seed export, so mis-sent assets cannot be recovered.
4. **Unclosed Boundless MPP channels**
   - When you chat in Boundless + Tempo mode, funds sit in a Tempo `USDC.e` payment channel until spent or refunded. Always click **Close** (instant cooperative refund) or **Withdraw** (unilateral 15-minute close) before switching Macs.
5. **Irreversible on-chain transfers & top-ups**
   - Ethereum Mainnet transfers/deposits, Base `USDC` x402 top-ups to Venice AI Credit, and Tempo `USDC.e` channel deposits are irreversible on-chain transactions. Double-check addresses, amounts, and gas fees before confirming.

## The 30-day protocol limit on untouched zkAPI deposits

In **zkAPI Anon Inference** mode, funding is a **two-step** flow:

1. **ETH Mainnet Wallet:** ETH sits in your local Cloak wallet under your control until you deposit or transfer it out.
2. **zkAPI Deposit:** Moving ETH into your active zkAPI deposit locks that ETH in the Open Anonymity / zkAPI protocol vault so Cloak can mint unlinkable one-time credentials for each turn.

**Important protocol rule — 30-day expiry:**
- Unused ETH in an active zkAPI deposit can be withdrawn back to your local ETH wallet **at any time within 30 days**.
- **After 30 days, an untouched zkAPI deposit expires at the protocol layer** and the zkAPI service operator can claim the remaining deposit, spent or not.
- Cloak helps protect against accidental expiry in three ways:
  - Displays your exact deposit expiry timestamp and warning badges in **Funds** and **Settings → Wallets**
  - Sends macOS notifications at **days 20, 25, and 28**
  - Offers an **Auto-withdraw 3 days before expiry** toggle
- **Important limitation:** Auto-withdraw and expiry reminders can only run while **your Mac is awake and Cloak is open and running**. If your Mac is powered off, asleep, wiped, or Cloak is paused past day 30, auto-withdraw will not fire and the untouched deposit can expire at the protocol layer.

## Best practices for Beta

- **Start small:** Fund `$5–$10` at a time (`$5` unlocks up to Tier 25 models in zkAPI; `$5` is the Venice x402 minimum top-up).
- **Back up Venice & Boundless keys immediately** if you hold more than pocket change: open **Funds** or **Settings → Wallets** and click **Export Private Key…** (store offline or in a password manager — never paste a private key into any chat).
- **Withdraw before wiping or switching Macs:**
  - **zkAPI:** Click **Withdraw** on any active deposit, wait for confirmation, then click **Transfer…** (`Max`) to sweep ETH to your external wallet.
  - **Boundless:** Click **Close** (or **Withdraw**) on any active deposit, then sweep or export your Tempo key.
  - **Venice:** Export your Base private key or spend down your Venice AI Credit.
- **Check gas before small Mainnet deposits:** Ethereum Mainnet gas fees can represent a noticeable fraction of a small `$3–$5` zkAPI deposit — Cloak always shows the exact ETH fee and dollar total on the 30-second quote screen before you click **Confirm Deposit**.
