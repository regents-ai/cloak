Cloak v0.2.1 (Beta) polishes onboarding, UI interactions, DMG branding, and payment/privacy safety across Token Inference, Venice, and zkAPI.

What's new in v0.2.1:
- Onboarding & UI Polish: Branded Cloak DMG volume icon, wider default Settings sidebar so all section titles stay visible without truncation, a new "Serve Inference to Earn" card in the Welcome Tour linking directly to Inference Serving settings, non-transient hover popovers so clicking the Agent pill or Tempo/Venice toggle while a tooltip is open triggers the control immediately, and full-capsule hit targets on both pills.
- Token Inference Provider-Switch Safety: Mid-thread provider-switch approvals are now strictly scoped to the single confirmed send and discarded automatically if auto-start, rewriting, or sending is cancelled or fails.
- Venice x402 Top-Up Safety: After an uncertain top-up over Tor, Top Up stays locked with a live EIP-3009 authorization countdown until a balance check confirms settlement (Base USDC drops or Venice credit rises) or the signed authorization expires unchanged.
- Non-Locking zkAPI Withdrawal Fee Preview: Clicking Withdraw now previews live Ethereum gas fees without reserving clearance or freezing chat spending—canceling keeps the deposit active. Auto-withdraw also checks live Ethereum gas fees before quoting so low-gas wallets never get frozen.

Beta & Wallet Security Notice: Cloak v0.2 is beta software and has not yet been independently audited. Keep wallet balances small, back up or withdraw funds before wiping or switching Macs (keys never sync to iCloud), and note the 30-day protocol limit on untouched zkAPI deposits. Read the full Wallet Security & Recovery guide at regents.sh/docs/cloak/wallets.

Share feedback at regents.sh/patchbay/cloak, github.com/regents-ai/cloak/issues, or @regents_sh on X.
