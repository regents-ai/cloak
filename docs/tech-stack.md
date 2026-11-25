# Regents Cloak — Mode & Integration Tech Stack Reference

> **Release scope:** `v0.2.0` (`regents-ai/cloak` v0.2.0 release tree; distributed via `regents-ai/cloak-releases`).  
> **Last verified against source:** `2026-11-24`.  
> **Audit status:** Cloak's privacy protections have not been independently audited.

Complete code-level map of every **mode** and **integration** in Regents Cloak (`v0.2.0`), showing:
1. **Where it is referenced** (UI surfaces, copy, icons, credits, docs, source pins)
2. **Where it is used at runtime** (Swift modules, helpers, guest binaries, protocols, endpoints, Keychain items, disk files, and tests)

---

## Table of Contents

- [0. System Overview: Ports, Keychain, Binaries & Pins](#0-system-overview-ports-keychain-binaries--pins)
- [1. Mode: Local (`vmlx-swift` MLX + `llama.cpp` GGUF & Unfiltered LoRA)](#1-mode-local-vmlx-swift-mlx--llamacpp-gguf--unfiltered-lora)
- [2. Mode: NEAR AI Gateway — NEAR AI Cloud (Intel TDX + NVIDIA TEE) & Trace Commons](#2-mode-near-ai-gateway--near-ai-cloud-intel-tdx--nvidia-tee--trace-commons)
- [3. Mode: Token Inference — Venice AI (Default, Base USDC x402 / API Key)](#3-mode-token-inference--venice-ai-default-base-usdc-x402--api-key)
- [4. Mode: Token Inference — Boundless + Tempo MPP (`USDC.e`)](#4-mode-token-inference--boundless--tempo-mpp-usdce)
- [5. Mode: zkAPI Anon Inference — Open Anonymity / zkAPI (Ethereum Mainnet)](#5-mode-anon-v--open-anonymity--zkapi-ethereum-mainnet)
- [6. Integration: Local Prompt Rewriter (`Qwen 3.5 9B`) & Detail Suggestions](#6-integration-local-prompt-rewriter-qwen-35-9b--detail-suggestions)
- [7. Integration: Tor Network, Linux MicroVM Sandbox, & Cover Traffic](#7-integration-tor-network-linux-microvm-sandbox--cover-traffic)
- [8. Integration: Local Agent Box (`Pi`) & Connected Apps Gateway (`CloakDoor`)](#8-integration-local-agent-box-pi--connected-apps-gateway-cloakdoor)
- [9. Integration: Inference Serving — Darkbloom](#9-integration-inference-serving--darkbloom)
- [10. Platform Shell: Storage, Widgets, CLI, Offline Data, & Signed Updates (`Sparkle`)](#10-platform-shell-storage-widgets-cli-offline-data--signed-updates-sparkle)

---

## 0. System Overview: Ports, Keychain, Binaries & Pins

### Host Modules (`app/Package.swift`, `host/Package.swift`, Swift 6.2, macOS 26+)

| Target / Package | Path | Role |
| :--- | :--- | :--- |
| `RegentsCloak` | `app/Sources/RegentsCloak/` | Native SwiftUI + AppKit menu-bar & window app |
| `CloakSupervisor` | `app/Sources/CloakSupervisor/` | Lifecycle state machine (`Phase`), manifest/SHA-256 verification, model downloads, local LLM & rewrite dispatch |
| `CloakChat` | `app/Sources/CloakChat/` | Encrypted chat store, Keychain wrappers, NEAR/Venice/Tempo/zkAPI/Agent protocol clients |
| `CloakDoor` | `app/Sources/CloakDoor/` | Local `127.0.0.1` OpenAI-compatible HTTP gateway for Connected Apps & guest Agent |
| `CloakControl` | `app/Sources/CloakControl/` | Unix-socket control protocol (`StatusDocument`, `Reason`), App Group `WidgetBridge` |
| `CloakWidgets` | `app/Sources/CloakWidgets/` | WidgetKit extension (Control Center switches + Desktop Privacy Posture widget) |
| `cloak` | `app/Sources/cloak/` | CLI (`status`, `doctor`, `start`, `pause`, `verify`, `stop`, `resume`) via `swift-argument-parser` `1.8.2` |
| `CloakHost` | `host/Sources/CloakHost/` | Apple `Virtualization.framework` guest boot, `tor` child process, `vsock` relays, framed `WorkerChannel` IPC |
| `RewriterKit` | `rewriter-kit/Sources/RewriterKit/` | Shared framed IPC wire protocol (`Frames`), multi-turn `Conversation`, and `Reply` parser shared by both local workers |

### Bundled Helper Binaries (Inside `Cloak.app/Contents/Resources/`)

| Binary / Artifact | Built From | Pinned Upstream | Role |
| :--- | :--- | :--- | :--- |
| `worker/cloak-worker-vmlx` + `mlx-swift_Cmlx.bundle` | `vmlx-worker/` | `osaurus-ai/vmlx-swift` (`52fdb628`) | Sandboxed pure-Swift MLX + JANGH2 + DSpark local chat worker |
| `worker/cloak-rewriter-llama` | `llama-worker/` | `ggml-org/llama.cpp` `b12633` (`9c10c94e`) | Sandboxed zero-HTTP Metal GGUF worker (prompt rewriter + GGUF chat + LoRA) |
| `near/cloak-near` | `guest/near/` | `dcap-qvl =0.7.1`, `rustls 0.23`, `chacha20poly1305 0.11` | Native arm64 Rust TEE verifier + E2EE v2 NEAR AI Cloud client |
| `tor/tor` + `tor/libevent-2.1.7.dylib` | `host/build.sh` | Tor Browser `16.0.1` (`tor 0.4.9.16`) | Host-managed Tor client on owner-only Unix SOCKS socket |
| `guest/Image` + `guest/initrd.gz` | `guest/build.sh` | Linux arm64 kernel + initramfs containing `cloak-sender`, `cloak-pay`, `zkapi-walletd`, `zkapi-clientd` (cover/check), `Node.js 24.22.2`, `Pi 1.3.0` | Ephemeral NIC-less Linux microVM (`2 vCPU`, `1 GiB RAM`, `vsock`-only) |

### Host ↔ Guest `vsock` Port Map

| `vsock` Port | Direction | Host Owner | Guest Service |
| :---: | :--- | :--- | :--- |
| `8012` | Guest → Host | `CloakHost/Relay.swift` | Guest daemon → Host `cloak-rewriter-llama` (startup check) |
| `8020` | Host → Guest | `CloakHost/Sender.swift` | `cloak-sender` (Venice + Boundless/Tempo over Tor) |
| `8021` | Host → Guest | `CloakHost/Pay.swift` | `cloak-pay` (zkAPI zkAPI Anon Inference payer + `zkapi-walletd` over Tor) |
| `8030` | Host → Guest | `CloakHost/Runner.swift` | Guest `Pi` coding agent runner |
| `8742` | Guest → Host | `CloakHost/Guest.swift` → `CloakDoor/Door.swift` | Guest `Pi` agent → Host OpenAI door (rewrites locally before paying) |
| `9050` | Guest → Host | `CloakHost/TorRelay.swift` → `Tor.swift` | Guest outbound TCP/DNS → Host `tor` Unix SOCKS5 socket |

### macOS Keychain Items (`KeychainStore.swift`: Data Protection Keychain on Provisioned Builds, This Device Only)

All six secrets flow through `app/Sources/CloakControl/KeychainStore.swift` (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Signed builds embedding `Contents/embedded.provisionprofile` (`367G3Z7G3J.sh.regents.cloak`) write to macOS's **Data Protection Keychain** (`kSecUseDataProtectionKeychain = true`, scoped to `keychain-access-groups` with no legacy login-keychain prompts on updates), with a non-destructive read fallback to legacy login-keychain items for seamless upgrades.

| Service Identifier | Account | Owner File | Holds |
| :--- | :--- | :--- | :--- |
| `sh.regents.cloak.conversations` | `conversations` | `CloakChat/Keychain.swift` | 256-bit ChaChaPoly master key sealing saved chats, `agents` passes, and Tempo `wallet/deposit` |
| `sh.regents.cloak.paydisk` | `payment disk` | `CloakSupervisor/PaymentDisk.swift` | 256-bit key unlocking guest LUKS2 1 GiB sparse disk (`payment-disk.img`) for zkAPI Anon Inference |
| `sh.regents.cloak.wallet` | `<0xAddress>` | `CloakChat/Remote.swift` (`WalletKeychain`) | 32-byte private key for Boundless / Tempo (`USDC.e`) wallet |
| `sh.regents.cloak.venice-wallet` | `<0xAddress>` | `CloakChat/Remote.swift` (`VeniceWalletKeychain`) | 32-byte separate private key for Venice Base (`USDC`) wallet |
| `sh.regents.cloak.near` | `near` | `CloakChat/Near.swift` (`NearKeychain`) | User's NEAR AI Cloud API key |
| `sh.regents.cloak.venice` | `venice` | `CloakChat/Keychain.swift` (`ProviderKeychain.venice`) | User's optional Venice Inference API key |

### Thread, Mode & Local Access Isolation

Every conversation thread in Cloak is **strictly self-contained** across both modes and separate threads within the same mode:

- **Per-thread context only:** Every send/ask path (`Chat.ask(_:in:)` for Local Mode; `Chat.send(_:in:)` for NEAR, Token Inference, and zkAPI Anon Inference) constructs its model request strictly from the active `Conversation`'s own `turns`. No model—local or remote—can read or query another conversation thread.
- **Mode locked on first turn:** The first message stamps the thread's mode (`llama`, `near`, `token`, or default `v`) via `Chat.mark(_:as:)`. A Local thread stays Local permanently and can never be routed to a cloud provider.
- **Offline-only Local Access boundary:** Opt-in Local Access features (`app/Sources/CloakChat/LocalContext.swift` — Mac info snapshot, Hermes-compatible `USER.md`/`MEMORY.md`, read-only Approved Local Folders, per-turn PDF/document/image-OCR/text attachments via picker or drag & drop, and macOS Calendar/Reminders/Contacts connectors) are wired **exclusively** inside `Chat.ask(_:in:)` for Local Mode. Cloud modes (`send(_:in:)`, `Agent.run`, and `CloakDoor`) have zero code path to them, and pending local attachments clear automatically when switching threads or leaving Local Mode.
- **MicroVM & Tor isolation:** Built-in Pi Agent threads run inside the ephemeral, NIC-less Linux microVM with per-conversation session IDs and zero access to macOS files, encrypted chats, or Local Access data. Each cloud thread receives its own random 32-byte Tor SOCKS5 identity (`Chat.identity(of:)`).
- **Explicit nuances:**
  - Enabled **Settings → Local Access** sources apply across Local Mode threads only (never cloud threads).
  - Toggling **Venice ↔ Boundless** mid-chat inside a single **Token Inference** thread intentionally carries that one thread's (locally rewritten) history to the newly selected Token Inference provider—still isolated from all other threads and modes.
  - Separate threads in **NEAR** (same API key) or **Token Inference** (same Venice or Boundless wallet) never share conversation content, though the provider can see both requests were paid by the same key or wallet. **zkAPI Anon Inference** breaks payment-level linkability per prompt.

---

## 1. Mode: Local (`vmlx-swift` MLX + `llama.cpp` GGUF & Unfiltered LoRA)

**Privacy model:** Once weights are downloaded, local inference does not send your conversation to an inference provider—no account, no payment, and no remote model calls during chat. (Model weight downloads connect directly to HuggingFace with SHA-256 verification, and Sparkle update checks are separate app-level network activity unless disabled in Settings.)

### 1.1 Places that *refer* to Local Mode
- **Chat mode definition, titlebar pill, empty header, onboarding card, & stop copy:**
  - `app/Sources/RegentsCloak/ChatView.swift`: `Chat.Kind.llama` (`"Local"`, symbol `laptopcomputer`), `EmptyChatHeader`, `TitlebarModePill`, `LocalOnboardingCard`, `LlamaCard`, `LlamaStop`, `ActiveGuaranteesView` (`"100% on this Mac"`), `AnswerStop` copy.
- **Welcome Tour:**
  - `app/Sources/RegentsCloak/TourView.swift`: Step 1 (`Cloak Local (16 GB+ Macs)`), Step 2 hardware-aware recommendation (`Local` card with live download progress or 8 GB Mac fallback to Private Cloud), Step 3 (`Models…` button).
- **Settings (`Settings → Local Models`):**
  - `app/Sources/RegentsCloak/SettingsView.swift`: `LlamaPane` (selectable chat models at top, `UnfilteredAdapterSection` toggle when a GGUF model with LoRA is selected, separate non-selectable `Prompt Rewriter` section at bottom), `ModelRow` (HuggingFace `↗` links, size, download/pause/remove).
- **Menu bar, shortcuts, & widgets:**
  - `app/Sources/RegentsCloak/MenuPanel.swift`: `Local` mode pill.
  - `app/Sources/RegentsCloak/RegentsCloakApp.swift`: `⌘1` (`Local Mode`), `cloak://action/newLocalChat`, `WidgetSnapshot.localReady`.
- **Credits, Notices, & Pins:**
  - `app/Sources/RegentsCloak/CreditsView.swift`: `vmlx-swift & Apple MLX`, `llama.cpp`, `Inkling 2 Mini` (JANGH2, GGUF, Unfiltered LoRA).
  - `app/Credits.html`, `THIRD_PARTY_NOTICES.md`, `app/release-notes.md`, `reference/sources.json` (`vmlx-swift` `52fdb628`, `llama.cpp` `b12633` `9c10c94e`).

### 1.2 Places that *use* Local Mode at runtime
- **Model catalog & RAM tiering:**
  - `app/manifest.py` & `app/Sources/CloakSupervisor/Manifest.swift`: defines `answerModels` with exact SHA-256 hashes, memory thresholds, and `engine` (`.vmlx` vs `.llama`):
    - `inkling-mini-jangh2` (`Inkling 2 Mini (Fast)`, `vmlx`, 10.21 GB, fits 16 GB+ Macs; measured ~56–64 tok/s on M4 Max 48 GB) — **default recommended on 16 GB+ Macs**.
    - `inkling-mini-ud-q3-gguf` (`Inkling 2 Mini (24 GB GGUF)`, `llama`, 13.63 GB, supports 44 MB `inkling-mini-uncensored-lora`).
    - `inkling-mini-nvfp4-gguf` (`Inkling 2 Mini (Full Quality)`, `llama`, 17.63 GB, supports 44 MB `inkling-mini-uncensored-lora`).
  - `app/Sources/CloakSupervisor/ModelDownload.swift`: resumable HTTPS downloader with `.part` files, free-disk checks, and strict SHA-256 verification before activating.
- **Chat dispatch, local attachments, & live lifecycle status:**
  - `app/Sources/CloakChat/Conversation.swift`: `Turn.thinking: String?` (encrypted on disk with the chat so Inkling 2 Mini keeps its full multi-turn thinking history) and `Turn.attachments: [AttachedFile]?` (metadata pills rendered on sent `LlamaCard` turns).
  - `app/Sources/CloakChat/LocalContext.swift`: `LocalAttachment.from(url:)` reads PDFs (via `PDFKit` + automatic on-device Apple Vision OCR fallback for scanned PDFs), images (`.png`/`.jpg`/`.heic`/`.webp`/etc. via on-device `VNRecognizeTextRequest`), rich documents (`.docx`/`.doc`/`.rtf`/`.rtfd`/`.odt` via `NSAttributedString`), and plain/UTF-16 text & code files; `LocalContextBuilder.attachmentsBlock(for:)` preserves session attachments across follow-up turns.
  - `app/Sources/RegentsCloak/Chat.swift` & `ChatView.swift` & `TextBox.swift`: `recommendedLocalDownload`, `answerDownload`, `activeUnfilteredLora`, off-main `attachLocalFiles(_:)` (sheet picker + `DroppingTextView` drag & drop), `ask(_:in:)` (streams partial tokens into `answering[id].partial`, tracks `LocalAnswerStage` via `Relay` `onWaking`/`onReady` callbacks so `LocalBusy` shows `Starting local model…` during cold boot, rotating answering phrases while thinking, and `Writing reply…` while streaming).
  - `app/Sources/CloakSupervisor/LocalLlama.swift`: encodes `[LocalMessage(role, content, reasoning)]` -> `/v1/chat/completions` JSON (`reasoning_content` on assistant turns), decodes `LocalAnswer(text, thinking)`, and defines `LocalAnswerStage`.
  - `app/Sources/CloakSupervisor/Supervisor.swift`: `isLocalModelWarm(_:lora:)`, `answer(_:with:lora:onStage:onPartial:)`, `openLocal(_:lora:)`, `Relay.restNow()` VRAM coordination (rests the rewriter worker before spawning a large GGUF worker on 16–24 GB Macs), idle unloading (`AppSettings.freeMemory`).
- **Dual Sandboxed Local Workers (shared wire protocol in `rewriter-kit/`):**
  - `rewriter-kit/Sources/RewriterKit/`: `Frames.swift` (`L` load, `Q` query, `P` streaming partial answer, `A` final answer, `C` cancel), `Conversation.swift` (accepts assistant `reasoning_content`, rejects user `reasoning_content` with HTTP 400), `Reply.swift` (splits `<think>…</think>`, returns `reasoning_content` in final JSON, never streams thinking to `P` frames).
  - `vmlx-worker/Sources/cloak-worker-vmlx/VmlxWorker.swift`: pure-Swift MLX/JANGH2/DSpark runtime (`osaurus-ai/vmlx-swift`), injects `reasoning_content` into `Chat.Message` dictionary for `chat_template.jinja`, strips reasoning before `P` streaming, enforces 8,192-token thinking budget (`422` if exhausted).
  - `llama-worker/Sources/CLlama/cloak_llama.cpp` + `llama-worker/Sources/CloakRewriterLlama/{Engine,Worker}.swift`: Metal `llama.cpp b12633` (`inkling2_loop` + PR `#32704` NVFP4 fix), supports `--lora` 44 MB uncensored LoRA, parses `reasoning_content` into `common_chat_msg.reasoning_content` with `enable_thinking = true`, `abort_callback` mid-chunk cancellation, 8,192-token thinking budget.
- **Tests:**
  - `app/Tests/CloakTests/StateMachineTests.swift` (`localModelTiersSelectByMacMemoryAndDecodeAdapter`, `localLlamaPreservesThinkingAcrossTurns`).

---

## 2. Mode: NEAR AI Gateway — NEAR AI Cloud (Intel TDX + NVIDIA TEE) & Trace Commons

**Privacy model:** Frontier model (`Qwen3.8-27B`) running in hardware-attested Intel TDX + NVIDIA GPU enclaves. Cloak independently verifies Intel TDX quotes & Intel Trust Authority GPU verdicts against pinned enclave measurements (`reference/near-pins.json`) and encrypts prompts end-to-end (E2EE v2) directly to the enclave's attested public key. Normal NEAR AI Gateway chats send your message as written (no local prompt rewriter). Paid with the user's NEAR AI Cloud API key, which identifies your NEAR account; optional Tor routing hides your IP using two separate Tor circuits per app launch (one for NEAR, one for Intel Trust Authority). Includes top-level **Chat**, **Traces** (opt-in local Letta Trajectory v1 export only—Cloak never uploads traces; review, redaction, submission, and any NEAR AI credits happen in the standalone NEAR AI Gateway app), and **Insights** tabs.

### 2.1 Places that *refer* to NEAR AI Gateway
- **Chat mode, top tab bar (`Chat | Traces | Insights`), titlebar pill, empty header, Tor switch, & hardware attestation badge:**
  - `app/Sources/RegentsCloak/ChatView.swift`: `Chat.Kind.near` (`"NEAR AI Gateway"`, symbol `cpu`), `EmptyChatHeader`, `TitlebarModePill`, `NearSwitches`, `NearStatus` (`Verified · now`, `Check failed`, `Checking NEAR's hardware…`), `NearStopRow`, `ActiveGuaranteesView` (`"Hardware TEE verified"`), sidebar `Export Trace` / `Remove Exported Trace` context menu & `arrow.up.doc` badge.
  - `app/Sources/RegentsCloak/NearGatewayView.swift`: `NearGatewayTabBar`, `NearGatewayTracesView`, `NearGatewayInsightsView`.
- **Settings (`Settings → NEAR AI Gateway`):**
  - `app/Sources/RegentsCloak/SettingsView.swift`: `NearPane` (Key save/replace/remove + `cloud.near.ai` link, `Route through Tor` toggle, `Share traces` toggle & folder controls, Model readout, NEAR/Gateway/Trace Commons/Dstack footer), `AdvancedPane` (`NEAR hardware check` proof freshness picker: Every message / 10 minutes / 1 hour).
- **Funds sheet (`Funds → NEAR AI Gateway`):**
  - `app/Sources/RegentsCloak/WalletView.swift`: `NearPayment` (Key status, `Set Up Key…`, Model, chat token counts, NEAR/Gateway/Trace Commons/Dstack footer), `WhyCryptoButton`.
- **Welcome Tour, Credits, & Notices:**
  - `app/Sources/RegentsCloak/TourView.swift`: Step 2 (`NEAR AI Gateway` card — recommended on 8 GB Macs).
  - `app/Sources/RegentsCloak/CreditsView.swift`, `app/Credits.html`, `THIRD_PARTY_NOTICES.md`, `app/release-notes.md`.

### 2.2 Places that *use* NEAR AI Gateway at runtime
- **Swift client, Keychain, & Trace Exporter:**
  - `app/Sources/RegentsCloak/NearMode.swift`: manages `hasKey`, `proof`, `checking`, `checkStop`, `route` (`.direct` vs `.tor(socket:near:intel:)` using separate Tor circuits for NEAR and Intel), `traces` (`NearTraces`), `check()`, `send(_:in:route:)`.
  - `app/Sources/CloakChat/NearTraceExporter.swift` & `app/Sources/RegentsCloak/NearTraces.swift`: exports answered NEAR AI Gateway chats (`Turn.sent` + reply) as Letta Trajectory v1 JSON (`source: "cloak"`, `Qwen/Qwen3.8-27B`) into owner-only `~/Library/Application Support/Regents Cloak/Traces` (excluded from Time Machine and Spotlight); refuses all non-NEAR or Agent chats.
  - `app/Sources/CloakChat/Near.swift`: `Near` helper subprocess manager (verifies `cloak-near` SHA-256 against manifest before spawning, speaks JSON-lines over stdin/stdout), `NearKeychain` (`sh.regents.cloak.near`), `Near.model = "Qwen/Qwen3.8-27B"` / `Near.displayModel = "Qwen3.8-27B"`.
  - `app/Sources/RegentsCloak/Chat.swift`: `sendNear`, auto-starts Cloak if `nearTor == true` and paused.
- **Native Rust TEE Verifier & E2EE Helper (`guest/near/` → `cloak-near`):**
  - `guest/near/Cargo.toml`: `dcap-qvl =0.7.1`, `chacha20poly1305 0.11.0`, `curve25519-dalek 4.1.3`, `hkdf 0.13.0`, `ring 0.17.14`, `rustls 0.23`.
  - `guest/near/src/verify.rs` & `guest/near/src/gpu.rs`: fetches attestation from `cloud-api.near.ai`, verifies Intel TDX quote via DCAP QVL, checks `app_compose` hash against embedded `reference/near-pins.json`, verifies Intel Trust Authority (`https://portal.trustauthority.intel.com`) PS384 JWT GPU verdict & nonce binding.
  - `guest/near/src/gate.rs` & `guest/near/src/chat.rs`: TLS certificate pinning to enclave key + E2EE v2 (`X25519` + `HKDF-SHA256` + `ChaCha20-Poly1305`) encryption of prompt and decryption of answer; fails closed on any pin/attestation mismatch.
  - `guest/near/src/bin/cloak-near.rs`: JSON-line helper loop (`check` and `ask` commands).
- **Tests:**
  - `guest/near` (`cargo test --locked`: **31 tests** covering DCAP verification, GPU verdict checks, pin/compose tampering, E2EE v2 vectors, proof age).
  - `app/Tests/CloakTests/NearTests.swift` (**3 test cases**).

---

## 3. Mode: Token Inference — Venice AI (Default, Base USDC x402 / API Key)

**Privacy model:** Remote inference over per-conversation Tor circuits with local prompt rephrasing (`Qwen 3.5 9B`). Venice AI's zero-data-retention policy and `Private` / `TEE` tier labels are **provider-reported by Venice**—Cloak filters to `Private` and `TEE` models by default and refuses silent mid-conversation tier downgrades, but unlike NEAR AI Gateway, Cloak does **not** independently verify a Venice TEE quote. Defaults to a dedicated local **Base USDC** wallet (`sh.regents.cloak.venice-wallet`, kept separate from the Boundless/Tempo wallet to avoid cross-chain address reuse), authenticating via Sign-In with Ethereum (SIWE) and topping up credit via HTTP `x402` (`EIP-3009` USDC transfer)—no Venice account or credit card required. Optionally accepts a user's own Venice Inference API key. A reused wallet address or API key can still link requests made with it.

### 3.1 Places that *refer* to Venice AI
- **Provider selection (`Funds → Token Inference`, default):**
  - `app/Sources/RegentsCloak/AppSettings.swift`: `PayProvider.venice` (`"Venice (Base USDC)"` / `"Venice"` — default), `venicePays` (`.wallet` vs `.key`), `veniceModel`, `veniceAllTiers` (`Settings → Advanced → Show all Venice tiers`).
- **Funds sheet (`VeniceFundsSections`):**
  - `app/Sources/RegentsCloak/WalletView.swift`: `Pay with` segmented picker (`Base USDC Wallet` / `Venice API Key`), Base USDC wallet creation/address/QR/balance, `$5`/`$10`/`$20`/custom x402 credit top-up, API key save/remove + `venice.ai/settings/api` link, Private/TEE model picker with per-1M token pricing, and `Powered by Venice AI (Docs · GitHub)` footer.
- **Chat UI, titlebar, & stops:**
  - `app/Sources/RegentsCloak/ChatView.swift`: `TitlebarModePill` (`Venice · <Model>` + Venice credit link), `EmptyChatHeader`, `TurnCard` (live streaming `chat.veniceMode.partial[turn.id]` + `Stop` button), `VeniceStopRow`, `ActiveGuaranteesView` (`"No account (local wallet)"`).
- **Credits, Notices, & Release Notes:**
  - `app/Sources/RegentsCloak/CreditsView.swift`, `app/Credits.html`, `THIRD_PARTY_NOTICES.md`, `app/release-notes.md`.

### 3.2 Places that *use* Venice AI at runtime
- **Swift protocol & wallet state:**
  - `app/Sources/RegentsCloak/VeniceMode.swift`: manages dedicated wallet presence, optional API key, 60-second cached model list (`Private` + `TEE` tiers by default, never remapped), on-chain Base USDC balance, Venice credit balance, x402 top-up guard (`adding`), and live streaming `partial[turn]`.
  - `app/Sources/CloakChat/Venice.swift`: Venice HTTP client targeting `https://api.venice.ai/api/v1/` (models, account balance, x402 `/x402/top-up` terms & payment, streaming `/chat/completions` SSE parsing, strict tier-change retirement).
  - `app/Sources/CloakChat/VeniceWallet.swift`: SIWE (`EIP-4361`) sign-in message builder, `SIGN-IN-WITH-X` header, `EIP-3009` `TransferWithAuthorization` typed data for Base USDC (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, Chain `8453`).
  - `app/Sources/CloakChat/Remote.swift`: `VeniceWalletKeychain` (`sh.regents.cloak.venice-wallet`), `Remote.veniceTransport`, `Remote.veniceSigner`, `Remote.veniceSign`, `Remote.veniceTyped`, `Remote.veniceFunds`.
  - `app/Sources/CloakChat/Keychain.swift`: `ProviderKeychain.venice` (`sh.regents.cloak.venice`).
  - `app/Sources/CloakSupervisor/Supervisor.swift` & `host/Sources/CloakHost/Sender.swift`: streaming `venice` exchange over `vsock` port `8020` (`L` head, `P` body chunks, `A` end).
- **Guest Linux VM (`guest/sender/` → `cloak-sender`, shared with Boundless):**
  - `guest/sender/src/lib.rs` & `guest/sender/src/main.rs`: handles concurrent connections over `vsock:8020` for ops `create`, `venice` (HTTPS streaming over Tor to `https://api.venice.ai` with per-conversation SOCKS5 credentials), `venice_sign` (EIP-191 SIWE only), `venice_typed` (EIP-712 Base USDC transfer only), and `venice_funds` (`eth_call` `balanceOf` against `https://mainnet.base.org` over Tor).
- **Tests:**
  - `app/Tests/CloakTests/VeniceTests.swift`, `app/Tests/CloakTests/StateMachineTests.swift` (`veniceModelsToleratesMalformedEntries`, `keychainServiceIdentifiersAreStrictlyIsolated`).
  - `guest/sender/tests/sender.rs`.

---

## 4. Mode: Token Inference — Boundless + Tempo MPP (`USDC.e`)

**Privacy model:** Accountless per-request payment channel over per-conversation Tor circuits with local prompt rephrasing (`Qwen 3.5 9B`). Uses HTTP 402 Machine Payments Protocol (`MPP`) sessions on Tempo Mainnet (`USDC.e`, Chain `4217`) with instant cooperative `Close` and unilateral on-chain `Withdraw` (15-minute grace period). Keeps its own Tempo wallet (`sh.regents.cloak.wallet`) separate from the Venice Base wallet to avoid cross-chain address reuse; a reused wallet or channel still links chats funded by it. Secondary provider in `Funds → Token Inference` and used by Token Inference Agent tasks.

### 4.1 Places that *refer* to Boundless + Tempo
- **Provider picker & labels:**
  - `app/Sources/RegentsCloak/AppSettings.swift`: `PayProvider.boundless` (`"Boundless (Tempo USDC.e)"` / `"Boundless"`).
- **Funds sheet (`WalletView`):**
  - `app/Sources/RegentsCloak/WalletView.swift`: `WalletSections`, `Account` (`USDC.e · Tempo`, `BoundlessTempoButton`), `Holding` (`Close` / `Withdraw`), `Models` (`Powered by Boundless on Tempo via MPP`), `RemoteStop.words`, `Amount.text` (`USDC.e`).
- **Brand marks & info popover:**
  - `app/Sources/RegentsCloak/ProviderMarks.swift`: `BrandMark.boundless`, `BrandMark.tempo`, `BoundlessTempoMarks`, `BoundlessTempoButton`, `BoundlessTempoNote`.
- **Chat & Door copy:**
  - `app/Sources/RegentsCloak/ChatView.swift`: `TitlebarModePill` bullet, `Chat.Kind.token` `paidWith` & fallback `credit`.
  - `app/Sources/CloakDoor/Failure.swift`: HTTP 402 `"Add USDC.e on Tempo…"` copy.
- **Credits, Notices, & Source Pins:**
  - `app/Sources/RegentsCloak/CreditsView.swift`, `app/Credits.html`, `THIRD_PARTY_NOTICES.md`, `app/release-notes.md`, `reference/sources.json` (`mpp-0.20.0.crate`).

### 4.2 Places that *use* Boundless + Tempo at runtime
- **Regular Token Inference chats (when `payProvider == .boundless`):**
  - `app/Sources/RegentsCloak/Wallet.swift`: `@Observable Wallet` (`find`, `create`, `refresh`, `close`, `withdraw`, `defaultModel = "deepseek/deepseek-v4-flash-0731"`).
  - `app/Sources/RegentsCloak/Chat.swift` & `ChatView.swift`: sends via `Remote.send(...)`, auto-refreshes wallet on startup only when `payProvider == .boundless`.
- **Token Inference *Agent* tasks (`Chat.Kind.token` + Agent pill ON):**
  - `app/Sources/RegentsCloak/Chat.swift` (`run` -> `agent.run(..., paying: .tempo, ...)`).
  - `app/Sources/CloakDoor/Door.swift` & `CloakChat/Pay.swift`: `Payment.tempo` routes guest Agent `/v1/models` and `/v1/chat/completions` through `Remote.models` / `Remote.complete`.
- **Keychain & sealed deposit file:**
  - `app/Sources/CloakChat/Remote.swift`: `WalletKeychain` (`sh.regents.cloak.wallet`), `DepositStore` (ChaChaPoly-sealed `wallet/deposit` with `forgetIfUnchanged` CAS guard), `Remote.look` / `send` / `complete` / `models` / `close` / `withdraw`.
- **Guest Linux VM (`guest/sender/` → `cloak-sender`):**
  - `guest/sender/Cargo.toml` & `guest/sender/src/lib.rs`: `mpp = "=0.20.0"`, `tempo-alloy = "=1.11.0"`, endpoints `https://api.inference.boundless.network/mpp` and `https://rpc.tempo.xyz`, ops `wallet`, `send`, `models`, `close`, `withdraw`.
- **Tests:**
  - `app/Tests/CloakTests/SendTests.swift`, `PayTests.swift` (`Payment.tempo` cases), `StateMachineTests.swift`, `guest/sender/tests/sender.rs` (**18 Rust tests**).

---

## 5. Mode: zkAPI Anon Inference — Open Anonymity / zkAPI (Ethereum Mainnet)

**Privacy model:** Maximum payment anonymity ("Paranoid Mode"). Every prompt is locally rephrased (`Qwen 3.5 9B`), routed over a per-conversation Tor circuit, and paid with a **fresh one-time zero-knowledge spend credential** (`zkapi-v2-note-bound-v1`) generated inside the Linux MicroVM from a pre-funded Ethereum Mainnet ETH deposit—avoiding any reusable wallet address, API key, or payment credential across model calls. Payment unlinkability does not prevent correlation from identifying text inside the prompt, multi-turn conversation history, or request timing.

### 5.1 Places that *refer* to zkAPI Anon Inference
- **Chat UI & Active Guarantees:**
  - `app/Sources/RegentsCloak/ChatView.swift`: `Chat.Kind.v` (`"zkAPI Anon Inference"`, symbol `theatermasks`), `TitlebarModePill`, `EmptyChatHeader`, `WalletButton` (live expiry warning badge), `ActiveGuaranteesView` (`"Unlinkable keys (zkAPI)"`), `TurnCard` (`PayStopRow`).
- **Funds sheet (`Funds → zkAPI Anon Inference`):**
  - `app/Sources/RegentsCloak/VWallet.swift`: `AddressSection` (ETH Mainnet address, Copy, QR, `Transfer…` popover), `DepositSection` (`$5`/`$10`/`$20`/custom USD deposit quote, 30-day expiry display, `Auto-withdraw 3 days before expiry` toggle, `Withdraw`), `ReviewRows` (fee + total in ETH & USD, 30 s countdown timer, Cancel/Confirm), `ModelSection` (live models & per-1M pricing + Open Anonymity / Vitalik links), `PayStopRow`.
  - `app/Sources/RegentsCloak/WalletView.swift`: `FundsTab.paranoid`, `ScrollViewReader` auto-scroll to `v-review-actions`, `WhyCryptoButton`.
- **Welcome Tour, Credits, Notices, & Source Pins:**
  - `app/Sources/RegentsCloak/TourView.swift`, `CreditsView.swift`, `app/Credits.html`, `THIRD_PARTY_NOTICES.md`, `app/release-notes.md`, `reference/sources.json` (`zkapi`, `zkapi-mainnet`, `zkapi-walletd`, `zkapi-walletd-protocol`).

### 5.2 Places that *use* zkAPI Anon Inference at runtime
- **Mac-side Payer, Queue, & Expiry Guard:**
  - `app/Sources/CloakChat/Payer.swift`: stateless mirror of the guest payer (`State`: `unread`, `none`, `depositing`, `ready`, `settling`, `withdrawing`, `taken`, `failed`), quote/review/confirm workflow (approves only unexpired quotes, double-approve guard, 10 s follow polling while money moves), live model & price reads, `send(_:in:identity:)`.
  - `app/Sources/CloakChat/PayQueue.swift` & `Pay.swift`: single serialized payment queue shared by Chat (`.owner` priority) and Connected Apps / Agent (`.door`), handles `H` (held/settling), `C` (completion), `V` (view), `A` (admin) frames.
  - `app/Sources/RegentsCloak/ExpiryGuard.swift`: schedules macOS `UNUserNotificationCenter` alerts at Days 20, 25, and 28 and optionally triggers automated withdrawal 3 days before 30-day vault expiry when enabled (`settings.autoWithdrawBeforeExpiry`).
  - `app/Sources/CloakSupervisor/PaymentDisk.swift`: creates/attaches 1 GiB sparse LUKS2 disk image (`payment-disk.img`) encrypted under `PaymentDiskKey` (`sh.regents.cloak.paydisk`). Keys and zkAPI note secrets **never leave the Linux guest**.
  - `host/Sources/CloakHost/Pay.swift`: host-side framed `vsock:8021` transport to `cloak-pay`.
- **Guest Linux VM (`guest/pay/` + `guest/image/pay-disk`):**
  - `guest/image/pay-disk`: opens/formats LUKS2 payment disk inside guest under dedicated `cloak-pay` user (isolated from `Pi` agent sandbox).
  - `guest/pay/zz_cloak_pay.go`, `zz_cloak_chain.go`, `zz_cloak_prices.go`, `zz_cloak_pay_linux.go` + patches (`client.patch`, `companion-start.patch`, `relay.patch`, `socks5.patch`): overlays `ethereum/zkapi` (`release/zkapi-server-time-mainnet-20261106`, vault `0x4386FDbdA35D995beB3BF8625118Ec5982ec81fe`) to listen strictly on `vsock:8021`, enforce per-conversation Tor identities, serialize settlement (`WaitSettled`), read on-chain state at one block, and expose `/cloak/prices`.
  - `zkapi-walletd` (Rust companion, `20aa542a`) + `zkapi-walletd-protocol` (`8b2d4e3d`) + 4 bundled SHA-256-verified proving/verifying keys (`request.pk`, `request.vk`, `withdrawal.pk`, `withdrawal.vk`, 13.7 MB).
- **Tests:**
  - `app/Tests/CloakTests/PayTests.swift`, `StateMachineTests.swift` (`payQueue*`, `payerPause*`).
  - `guest/pay/check.sh` (`guest/pay/zz_cloak_pay_test.go`, Go unit + integration tests inside Docker/Go).

---

## 6. Integration: Local Prompt Rewriter (`Qwen 3.5 9B`) & Detail Suggestions

**Privacy model:** Rephrases user text locally on-device before any Token Inference, zkAPI Anon Inference, Agent, or Connected App prompt leaves over Tor to reduce stylometric fingerprints (slang, tone, filler, irrelevant framing). **Important limit (`Rewrite.swift:85-93`):** The rewriter explicitly preserves code, exact quotations, names, identifiers, paths, URLs, written numbers, and exact-output constraints verbatim so technical prompts stay usable—it does **not** automatically redact necessary identifiers. Fails closed (a rewrite failure never sends the original text).

### 6.1 Places that *refer* to Prompt Rewriting
- **Settings:**
  - `app/Sources/RegentsCloak/SettingsView.swift`: `GeneralPane` (`Prompt rewriting` 3-way picker: *Review before sending* / *Automatic* / *Off*), `LlamaPane` bottom non-selectable **`Prompt Rewriter`** section (`Qwen 3.5 9B`, 5.69 GB), `NeverReword` toggle.
  - `app/Sources/RegentsCloak/Details.swift` (`Settings → Status`): `Rewriter` status readout (`Qwen 3.5 9B` / `unloaded`) and `DownloadSection` when not installed.
- **Chat UI & Menu Panel:**
  - `app/Sources/RegentsCloak/ChatView.swift`: `TurnCard` (side-by-side `Original` vs `Rewritten` with `WordDiff` red/green highlights, `Send Original Text` menu), `PendingCard`, `RewordingElsewhere`, `Waiting` (`Download Model…` when rewriter not yet installed), `ActiveGuaranteesView` (`"Local prompt rewrite"`).
  - `app/Sources/RegentsCloak/DetailsRow.swift`: live interactive detail-suggestion chips above the composer box.
  - `app/Sources/RegentsCloak/MenuPanel.swift`: rewriter download banner & `"Running · rewriter resting"` status.

### 6.2 Places that *use* Prompt Rewriting at runtime
- `app/Sources/CloakSupervisor/Rewrite.swift`: builds strict rewrite prompt (`maxCharacters`, dynamic deadline) and calls `Relay` on `cloak-rewriter-llama`.
- `app/Sources/CloakSupervisor/Details.swift` & `DetailPicks.swift`: debounced speculative detail extraction (`Details.run`), preempted immediately by any real rewrite or chat request.
- `app/Sources/CloakSupervisor/Supervisor.swift`: `rewrite(_:)`, `details(for:)`, `Relay.Resting` (unloads rewriter after `AppSettings.freeMemory` idle timeout, default 15 min, wakes seamlessly on next request).
- `app/Sources/CloakDoor/Door.swift`: `rewriteInOrder(for:asked:)` — serializes per-app/per-agent conversation rewrite memory so multi-turn transcripts stay consistent and never skip rewriting.
- `llama-worker/`: zero-HTTP Metal `llama.cpp b12633` helper running pinned `unsloth/Qwen3.5-9B-GGUF` (`Qwen3.5-9B-Q4_K_M.gguf`, 5.69 GB, SHA-256 verified) with GBNF grammar constraints & static system-prompt KV prefix reuse.

---

## 7. Integration: Tor Network, Linux MicroVM Sandbox, & Cover Traffic

**Privacy model:** All remote inference in Tor modes (Venice, Boundless, zkAPI Anon Inference, optional NEAR Tor, Agent tools, Connected Apps) leaves exclusively through a bundled `tor` process with `IsolateSOCKSAuth` and remote DNS resolution: Token Inference and zkAPI Anon Inference use **per-conversation** Tor circuits; Cover Traffic uses a **fresh circuit per fetch**; NEAR AI Gateway (when Tor is ON) uses **two circuits per app launch** (one for NEAR, one for Intel Trust Authority). The Linux guest has **no virtual NIC**—its only egress is `vsock:9050` into the host's Tor relay.

### 7.1 Places that *refer* to Tor, Sandbox, & Cover Traffic
- **UI & Status:**
  - `app/Sources/RegentsCloak/WalletView.swift`: `StartupProgressView` (5 live startup steps: Checking → Tor → Rewriter → VM → Verifying).
  - `app/Sources/RegentsCloak/MenuPanel.swift`: instant `Cover Traffic` toggle (zero VM/app restart), live startup checklist, Start/Pause controls.
  - `app/Sources/RegentsCloak/SettingsView.swift`: `AdvancedPane` (`Cover Traffic` section explaining what it fetches + toggle + live append-only log + `Clear Last Hour` / `Clear All` / `Copy Log`), `NearPane` (`Route through Tor` toggle).
  - `app/Sources/RegentsCloak/ChatView.swift`: `ActiveGuaranteesView` (`"Tor routing active"`, `"Cover traffic active"`), `Lights` (Tor indicator), `NearSwitches` (`Tor` pill).
  - `app/Sources/CloakControl/Status.swift`: `Reason` (`torUnavailable`, `torStopped`, `guestFailed`, `checkFailed`, etc.).
- **Credits, Notices, & Pins:**
  - `app/Sources/RegentsCloak/CreditsView.swift`, `app/Credits.html`, `THIRD_PARTY_NOTICES.md`, `reference/sources.json` (`tor` 16.0.1 / 0.4.9.16), `reference/cover.json` (58-URL approved pool).

### 7.2 Places that *use* Tor, Sandbox, & Cover Traffic at runtime
- **Tor lifecycle (`host/Sources/CloakHost/Tor.swift` & `TorRelay.swift`):**
  - Spawns bundled `tor 0.4.9.16` with `--SocksPort unix:<tempdir>/socks IsolateSOCKSAuth`, `--DataDirectory ~/Library/Application Support/Regents Cloak/tor`, `--__OwningControllerProcess <pid>`.
  - `waitForLockRelease` (`flock(LOCK_EX | LOCK_NB)` up to 18 s) cleanly absorbs stale `tor` exit after a crash/force-quit.
  - `TorRelay` bridges guest `vsock:9050` connections to the host's Unix SOCKS5 socket and strips socket-vs-TCP response differences for `torsocks`.
- **Host-side Live Cover Traffic & Append-Only Log (`app/Sources/CloakSupervisor/CoverTraffic.swift`):**
  - Runs natively on the host over Tor's Unix SOCKS5 socket (`ProxyConfiguration(socksv5Proxy: .unix(path:))`) with a unique `IsolateSOCKSAuth` credential per fetch, fetching ~3 random HTTPS pages/minute (15–30 s jitter) from 16 session-sampled URLs in `reference/cover.json`.
  - Records every fetch (timestamp, URL, HTTP status, byte size, latency) to an owner-only (`0600`), Time-Machine-excluded append-only log at `~/Library/Application Support/Regents Cloak/cover-log.jsonl` (viewable and clearable in `Settings → Advanced`).
  - `Supervisor.syncCover()` starts/stops Cover Traffic instantaneously while Running with **zero Tor, rewriter, or Linux VM restart**; the guest boots with `cover: false` (while `zkapi-clientd` remains inside the guest for startup self-checks).
- **NIC-less Linux MicroVM (`host/Sources/CloakHost/Guest.swift`, `BootFiles.swift`, `guest/image/`):**
  - Uses Apple `Virtualization.framework` (`VZVirtualMachine`, `VZVirtioSocketDevice`, `VZVirtioEntropyDevice`, `VZVirtioBlockDevice` for LUKS2 payment disk; **zero** `VZVirtioNetworkDevice`).
  - `BootFiles.swift` writes ephemeral channel token, rewriter key, and empty guest cover URL list (`cover: false`), wiping them on launch/shutdown.
  - `guest/image/boot` starts `cloak-pay`, `cloak-sender`, `cloak-runner`, and the reference `zkapi-clientd` daemon (for startup self-check).
- **Supervisor orchestration (`app/Sources/CloakSupervisor/Supervisor.swift`):**
  - `prepare()` verifies all manifest SHA-256 hashes, starts `tor` → `cloak-rewriter-llama` → `Guest` → startup end-to-end verification check; `syncCover()` applies Cover Traffic toggles immediately without restarting the supervisor; `NSWorkspace.willSleepNotification` pauses cleanly on sleep.

---

## 8. Integration: Local Agent Box (`Pi`) & Connected Apps Gateway (`CloakDoor`)

**Privacy model & rewrite scope (`CloakDoor/Asked.swift:5-18`):**
- **Local Agent Box:** Runs multi-step shell/file coding tasks (`bash`, `read`, `edit`, `write`) inside the sealed Linux MicroVM so tools never touch macOS files, with all model requests routed back through `CloakDoor` (user-message text rephrased locally + paid over Tor) and outbound shell traffic forced through `torsocks` on a per-conversation Tor circuit.
- **Connected Apps:** Exposes a localhost-only OpenAI-compatible API (`http://127.0.0.1:8742/v1`) with per-app bearer passes (`cloak-<64 hex>`, only SHA-256 stored in ChaChaPoly-sealed `agents` file) for Cursor, Cline, Continue, Aider, etc. **Important boundaries:** Connecting an external Mac app changes its **inference endpoint** (`127.0.0.1:8742/v1` → zkAPI Anon Inference `zkAPI`), **not** its macOS filesystem or network permissions—only Cloak's built-in `Pi` agent runs inside the sealed Linux VM. In both Connected Apps and Agent runs, `CloakDoor` rephrases **only `role == "user"` text parts**; `system` / `developer` instructions, `tools` definitions, `tool` results (including source code), `assistant` messages, and accepted image/audio/file parts pass through unchanged.

### 8.1 Places that *refer* to Agent & Connected Apps
- **Connected Apps (`Settings → Connected Apps`):**
  - `app/Sources/RegentsCloak/AgentsView.swift`: Base URL copy, door status (`Open`/`Closed`/`Opening`/`Can't open` with `Change Port…` & `Try Again`), `Manage Funds…`, `Apps` list (`AddApp` one-time API key sheet, remove confirmation), in-memory `Activity` log (`RequestRow` + `RequestTexts` Original-vs-Sent diff sheet).
  - `app/Sources/RegentsCloak/SettingsView.swift`: `AdvancedPane` (`PortRow`, default `8742`).
- **Local Agent Box (Chat):**
  - `app/Sources/RegentsCloak/ChatView.swift`: `AgentPill` (hammer toggle + hover popover), `TaskCard` (live `StepList` with full-row collapsible `N steps`, `Stop`, `Run Again`), `EmptyChatHeader` (`Local Agent Box`), `ActiveGuaranteesView` (`"Sealed local agent box"`).
- **Credits & Pins:**
  - `app/Sources/RegentsCloak/CreditsView.swift`, `app/Credits.html`, `THIRD_PARTY_NOTICES.md`, `reference/sources.json` (`pi` `@earendil-works/pi-coding-agent@1.3.0`, `node` `v24.22.2`).

### 8.2 Places that *use* Agent & Connected Apps at runtime
- **OpenAI Gateway (`app/Sources/CloakDoor/`):**
  - `Door.swift`, `HTTP.swift`, `Asked.swift`, `Failure.swift`: `Network.framework` `NWListener` bound strictly to `127.0.0.1:<doorPort>` (`acceptLocalOnly = true`), rejects cross-site browser `Origin`/`Sec-Fetch-Site` headers, serves `/v1/models` and `/v1/chat/completions`, rewrites all user messages via `Supervisor.rewrite`, drops unpaid disconnects, and tracks the latest 20 requests in memory only.
  - **Payment routing in `Door.swift`:**
    - External macOS apps (`Side.mac`) → always **zkAPI Anon Inference (`.zkapi`)** via `PayQueue` (`.door` rank behind interactive Chat).
    - Guest Agent (`Side.guest`) in zkAPI Anon Inference → **`.zkapi`**.
    - Guest Agent (`Side.guest`) in Token Inference → **`.tempo`** (Boundless/Tempo wallet).
- **Agent Runner:**
  - `app/Sources/CloakChat/Agent.swift` & `PiEvent.swift`: manages per-conversation agent runs, decodes Pi JSONL tool events into `Step`s, cancels cleanly on Stop/Pause/Delete.
  - `app/Sources/CloakSupervisor/AgentTasks.swift` & `host/Sources/CloakHost/Runner.swift`: streams task request & events over `vsock:8030` to the guest's `Node.js 24.22.2` + `Pi 1.3.0` runner.
- **Tests:**
  - `app/Tests/CloakTests/AgentTests.swift`, `PayTests.swift` (door cancellation & payment queue priority).

---

## 9. Integration: Inference Serving — Darkbloom

**Release status:** Built into Cloak (`-DDARKBLOOM` enabled by default in `app/build.sh` and `app/release.sh`); requires macOS 27+.

### 9.1 Places that *refer* to Darkbloom
- `app/Sources/RegentsCloak/DarkbloomView.swift`: **"Inference Serving"** settings pane (`DarkbloomBrandHeader`, unified 3-way animated glowing `ServingModeControl` (`Off` / `Local Only` / `Network + Local`), ranked multi-model selector with `Serving` & `Top Earner` badges, inline `Switch` button for selected downloaded models, `Show N more fitting models`, `Live Monitor` telemetry including daemon uptime / served requests / output tokens, `Local API (For Other Apps)` endpoint + show/copy key + route safety badge, and full-row `CLI & Troubleshooting` disclosure with `Run Doctor` / `Run Status`, copyable Terminal commands, Remove Model, After Quit, At Login, and Version).
- `app/Sources/RegentsCloak/ProviderMarks.swift`: `BrandMark.darkbloom`, `BrandMark.eigenLabs`, `DarkbloomBrandHeader` (`Eigen Labs ↗`, `GitHub ↗`).
- `app/Sources/RegentsCloak/MenuPanel.swift` (`Serving` tile), `RegentsCloakApp.swift` (`showDarkbloom`, `cloak://action/openServing`, widget serving stats), `Scripting.swift` & `app/RegentsCloak.sdef` (`show darkbloom`), `CreditsView.swift`, `app/Credits.html`, `THIRD_PARTY_NOTICES.md`.

### 9.2 Places that *use* Darkbloom at runtime
- `app/Sources/RegentsCloak/DarkbloomClient.swift`:
  - Verifies `~/.darkbloom/bin/darkbloom` strict macOS code signature (`io.darkbloom.provider`, Team `SLDQ2GJ6TL`, pinned leaf cert hash) and minimum version (`0.10.16`), caching verified binary metadata by `(path, inode, mtime)` to avoid repeated `codesign` subprocess spikes.
  - Installs/updates via `https://api.darkbloom.dev/install.sh` (5-step progress) when user clicks Install/Update.
  - Discovers local control service via `~/.darkbloom/desktop/connection.json` (`127.0.0.1:<port>/control/v1/{state,events,actions,endpoint-key}`, no redirects, no proxies, stale-PID check) and reads `~/.darkbloom/daemon-state.json` directly for instant `<0.1 ms` menu-bar status without blocking the serialized control RPC.
  - Reads `~/Library/LaunchAgents/io.darkbloom.provider.plist` (including active `--model` flag for `--local` mode), `~/.darkbloom/local.json`, and `~/.config/darkbloom/provider.toml` (`DarkbloomSetup`) to audit route (`--route this-mac`) and loopback binding (`--bind 127.0.0.1`).
  - Fetches live per-million-token payout rates from `https://api.darkbloom.dev/v1/pricing` (`DarkbloomPricing`, 0% platform cut).
- `app/Sources/RegentsCloak/DarkbloomMode.swift`:
  - Computes memory room (`pinBudgetGb - cloakMemory`), filters `eligible && network && fits`, ranks all fitting models highest payout first (`75% output + 25% input`), persists choice in `UserDefaults` (`darkbloomModel`), drives download/cancel/remove/start/switch/stop/link operations, decodes `0.10.17` `activity` telemetry (`uptime`, `requests`, `outputTokens`), and subscribes to live SSE snapshots while the Settings window is open (`NSWindow.didBecomeKeyNotification` / `willCloseNotification`).

---

## 10. Platform Shell: Storage, Widgets, CLI, Offline Data, & Signed Updates (`Sparkle`)

| Subsystem | Files | How It Works |
| :--- | :--- | :--- |
| **Encrypted Disk Storage** | `CloakChat/ConversationStore.swift`, `CloakControl/ControlSocket.swift` (`Places`), `CloakSupervisor/CoverTraffic.swift` | Stores chats (`conversations/*.chat`), Connected Apps (`agents`), Tempo deposit (`wallet/deposit`), Tor state (`tor/`), zkAPI Anon Inference LUKS2 disk (`payment-disk.img`), exported NEAR traces (`Traces/`), cover-traffic log (`cover-log.jsonl`, `0600`, Time-Machine-excluded), local memories (`memories/{USER,MEMORY}.md`), offline datasets (`OfflineData/`), and models (`models/`) inside owner-only (`0700`) `~/Library/Application Support/Regents Cloak/`. Chats, apps, and Tempo deposit are ChaCha20-Poly1305 authenticated under `sh.regents.cloak.conversations`. |
| **Menu Bar & Quick Prompt** | `RegentsCloak/Menu.swift`, `MenuPanel.swift`, `QuickPrompt.swift` | Liquid Glass `NSPanel` anchored to `NSStatusItem` with status, live 5-step startup progress, inline Quick Draft, mode pills, Cover toggle, and action grid. Global shortcut (`Settings → Advanced → Quick prompt`) uses Carbon hotkeys—zero Accessibility permission required. |
| **Control Center & Desktop Widgets** | `CloakWidgets/CloakWidgetBundle.swift`, `CloakControl/WidgetBridge.swift`, `RegentsCloak/CloakIntents.swift` | Shares non-sensitive `WidgetSnapshot` via App Group `367G3Z7G3J.sh.regents.cloak` and dispatches control-only `cloak://action/<cmd>` deep links (never prompt text or secrets). |
| **CLI & Scripting** | `cloak/Cloak.swift`, `CloakControl/ControlSocket.swift`, `RegentsCloak/Scripting.swift` | `cloak` talks to `RegentsCloak` over an owner-only Unix socket (`~/Library/Application Support/Regents Cloak/control/cloak.sock`). Single-instance lock via `flock` (`Instance.claim()`). |
| **Offline Data** | `CloakChat/OfflineDatasets.swift`, `RegentsCloak/OfflineDataManager.swift`, `SettingsView.swift` (`OfflineDataPane`) | Progressive, resumable **Minimum → Maximum** direct downloads (remembering downloaded tier) for **Kiwix Library** (`174 MB → 61 GB`), **DevDocs** (`15 MB → 240 MB`, 1-click linkable into Local Mode), **CourtListener Bulk Data** (`540 KB → 58.3 GB`), **PubMed Central Open Access** (anonymous AWS S3 CLI), and **Tinfoil Kit** (`github.com/tudor-city-ventures/tinfoil-kit`). |
| **First-Launch Install UX** | `RegentsCloak/MoveToApplications.swift`, `TourView.swift` | Detects DMG (`/Volumes/`), App Translocation, `~/Downloads`, or `~/Desktop` launches and offers 1-click `ditto` copy to `/Applications` + quarantine clear + clean relaunch. First launch opens `Local` mode with the 3-step hardware-aware Welcome Tour. |
| **Signed Updates & Release Verification** | `RegentsCloak/Updates.swift`, `ReleaseVerification.swift`, `Details.swift`, `app/release.json`, `app/release.sh`, `app/publish.sh` | EdDSA-signed Sparkle 2 (`2.8.1`) feed at `https://raw.githubusercontent.com/regents-ai/cloak-releases/main/appcast.xml`, Developer ID signed (`367G3Z7G3J`), hardened runtime, notarized & stapled DMGs (`CFBundleVersion` = git commit count, `CFBundleShortVersionString` = `0.2.0`). `app/release.sh` + `app/publish.sh` publish `SHA256SUMS.txt` and `checksums.json` (DMG SHA-256, binary SHA-256, `CDHash`, Team ID); **Settings → Status** displays live `CryptoKit.SHA256` + `SecCodeCopySigningInformation` `CDHash` alongside copy-paste macOS `shasum`, `codesign`, and `spctl` verification commands. |
| **Credits, Licensing, & Feedback** | `RegentsCloak/CreditsView.swift`, `SettingsView.swift` (`FeedbackPane`), `app/Credits.html`, `THIRD_PARTY_NOTICES.md` | Full attributions, clickable website/GitHub links, offline license viewer, `build@regents.sh`, `@regents_sh` (X), `github.com/regents-ai/cloak`, and `regents.sh/patchbay/cloak` (+ Copy Agent Prompt). |
| **Card / Apple Pay On-Ramp** | `RegentsCloak/OnRamp.swift`, `WalletView.swift`, `VWallet.swift` | Non-custodial checkout sheet (`Base USDC` / `Ethereum ETH`) activated via `CloakOnRampSessionURL` or `CloakCoinbaseOnRampAppID` in `Info.plist`. |
