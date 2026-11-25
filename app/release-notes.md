Cloak v0.2.5 (Beta) adds an optional direct (no-Tor) toggle for Token Inference (Boundless & Venice) and streamlines the Welcome Tour with a new Quickstart guide and clear Tor vs. speed guidance.

What's new in v0.2.5:
- Optional Direct (No-Tor) Mode for Boundless & Venice: Toggle Tor off in Token Inference (directly below Chat, in the menu bar panel, in Funds, or in Settings → Wallets) to connect over direct HTTPS using the pinned macOS cloak-sender helper with no Linux VM or Tor startup delay (works on 8 GB+ Macs too, while still rewriting prompts locally on 16 GB+ Macs when the rewriter is installed). Tor stays on by default to protect your IP, and Local Agent Box (Pi) continues to run inside the sealed Linux microVM over Tor.
- Redesigned 3-Step Welcome Tour & Quickstart: Starts directly on "Welcome to Cloak" with an upfront explanation of when Tor is used and its latency tradeoff, moves Agent Mode & Power Tools to Step 2, and adds a new Step 3 "Quickstart" showing exactly how to begin each mode (Local model download, NEAR API key, Tempo USDC.e / Base USDC / Venice API key, and Ethereum Mainnet ETH for zkAPI).

Beta & Wallet Security Notice: Cloak v0.2 is beta software and has not yet been independently audited. Keep wallet balances small, back up or withdraw funds before wiping or switching Macs (keys never sync to iCloud), and note the 30-day protocol limit on untouched zkAPI deposits. Read the full Wallet Security & Recovery guide at regents.sh/docs/cloak/wallets.

Share feedback at regents.sh/patchbay/cloak, github.com/regents-ai/cloak/issues, or @regents_sh on X.
