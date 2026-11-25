Cloak v0.2.2 (Beta) refines the macOS menu bar experience, enables app-wide selectable text, hardens Venice top-up persistence and Dev isolation, and clarifies privacy/attachment/Connected Apps behavior.

What's new in v0.2.2:
- Menu Bar & Sidebar Polish: Eliminated rectangular dark shadow artifacts in the rounded corners of the Liquid Glass menu bar panel, anchored the right-click quick menu natively so the header never clips under a scroll chevron, synced right-click quick actions with the new panel (including Funds), and removed the duplicate "+ New chat" sidebar row when starting with zero chats.
- Copyable Text Everywhere: Enabled native text selection across Settings, Funds/Wallets, Connected Apps, Inference Serving, Credits, and the menu bar panel so notices, error messages, and details can be highlighted and copied directly.
- Persistent Venice Top-Up Guard: Pending uncertain Venice x402 top-ups now persist across app restarts and require a full top-up balance delta (not a 1-cent wiggle) before unlocking another payment while the EIP-3009 authorization can still settle.
- Precise Privacy Copy & Honest Attachments: Tightened zkAPI copy to clearly distinguish payment unlinkability from multi-turn prompt/history correlation, added "Reattach to use" badges when persisted Local Mode attachment text was cleared on quit, documented CloakDoor's buffered SSE and message/size limits in Connected Apps, and added a keyboard-focusable info button beside the Agent pill.
- Cloak Dev Build Isolation: Fixed `app/build.sh dev` so Cloak Dev registers strictly `cloak-dev://` (never intercepting production `cloak://` links), updated URL handling to match the active bundle scheme, and added a shared-daemon warning banner in Dev's Inference Serving pane.

Beta & Wallet Security Notice: Cloak v0.2 is beta software and has not yet been independently audited. Keep wallet balances small, back up or withdraw funds before wiping or switching Macs (keys never sync to iCloud), and note the 30-day protocol limit on untouched zkAPI deposits. Read the full Wallet Security & Recovery guide at regents.sh/docs/cloak/wallets.

Share feedback at regents.sh/patchbay/cloak, github.com/regents-ai/cloak/issues, or @regents_sh on X.
