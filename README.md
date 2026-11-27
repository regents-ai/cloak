<p>
  <img src="docs/media/cloak-crown.gif" width="120" height="120" alt="Regents Cloak" />
</p>

# Cloak

Cloak is a macOS menu bar app for private AI — local on Apple Silicon, or routed to remote models with explicit, inspectable privacy boundaries and a 3-tier Security Profile.

[Website](https://regents.sh/cloak) · [Docs](https://regents.sh/docs/cloak/reference) · [Releases](https://github.com/regents-ai/cloak/releases) · [Changelog](CHANGELOG.md)

![Cloak](docs/media/cloak-hero.jpg)

> **Status (`v0.3.0 Beta`):** Signed, notarized `.dmg` builds are published directly on [GitHub Releases](https://github.com/regents-ai/cloak/releases). Cloak is **beta software** and its privacy protections have not yet undergone an independent security audit — keep wallet balances small, back up or withdraw funds before wiping your Mac, and read the [Wallet Security, Recovery & 30-Day zkAPI Limit](docs/wallet-security.md) guide ([web copy](https://regents.sh/docs/cloak/wallets)).

## Install

Download `Regents-Cloak.dmg` from [Releases](https://github.com/regents-ai/cloak/releases), drag **Cloak** into `/Applications`, and open it.

Verify any download independently using macOS's built-in Terminal tools and compare against `SHA256SUMS.txt` on GitHub Releases, [regents.sh/cloak/install#verify](https://regents.sh/cloak/install#verify), and **Settings → Status** inside the app:

```sh
shasum -a 256 ~/Downloads/Regents-Cloak.dmg
codesign -dvv --strict "/Applications/Cloak.app"
spctl --assess --type execute -vv "/Applications/Cloak.app"
```

Requires Apple Silicon and macOS 26 or later (macOS 27+ for optional Darkbloom inference serving).

## Security Profiles

Choose your privacy posture in **Settings → General → Security Profile** — Cloak enforces it across Chat, Connected Apps (`CloakDoor`), Wallets, Tor/VM controls, and Inference Serving:

| Security Profile | Allowed | Hard-blocked |
| --- | --- | --- |
| **Local Only + Downloads** | Local Chat (`vmlx-swift` / `llama.cpp` / loopback `127.0.0.1` servers), Local Access, Local Voice, Saved Project Profiles, Connected Apps (`Local $0`), explicit model & offline dataset downloads, Darkbloom `Local Only` | All cloud AI chat modes, cloud Connected Apps rails, cloud wallets & on-chain RPCs, Tor/VM cloud sends, and account-linked Network Inference Serving |
| **Anon Private Cloud** | Everything in Local Only + **zkAPI Anon Inference** (one-time ZK credentials) with **Tor**, **Cover Traffic**, and **Local Prompt Rewriting** locked **ON**; Connected Apps on `Local ($0)` and `zkAPI Anon` | Account-keyed NEAR AI Gateway, single-wallet linkable Venice & Boundless rails, direct non-Tor cloud traffic, skipping prompt rewriting, and account-linked Network Inference Serving |
| **Private Cloud AI** *(default)* | All 4 Chat modes, Smart Private Router, all 5 Connected Apps rails (`Local`, `NEAR TEE`, `Venice · Base`, `Boundless · Tempo`, `zkAPI Anon`), all wallets, Darkbloom `Network + Local`, and verified cloud integrations | Enforces per-thread mode locks, Privacy Shield secret blocking, Spend Guardrails, and fail-closed verification |

## How it works

Cloak lives in your menu bar and starts paused. **Local** (`⌘1`), **NEAR AI Gateway** (`⌘2`, with Tor off), **Venice** (with direct HTTPS enabled), and **Local `CloakDoor`** work immediately without starting the VM.

When you press **Start**, Cloak launches bundled Tor (`0.4.9.16`), a sandboxed local prompt rewriter (`Qwen 3.5 9B`), and an ephemeral, NIC-less Linux arm64 microVM (`Virtualization.framework`). Outbound traffic from the VM can only exit through Tor over `vsock:9050`. Models load on demand and unload automatically when idle so they do not hold unified memory when not in use.

<p>
  <img src="docs/media/cloak-startup.png" width="460" alt="Cloak 5-step verified startup checklist" />
</p>

You can chat directly in Cloak (with text or on-device **Local Voice**), isolate client/codebase contexts with **Saved Project Profiles**, toggle the built-in sandboxed **Pi** coding agent (`hammer` icon), or connect external coding tools (`Claude Code`, `OpenCode`, `Goose`, `Cursor`, `Cline`, `Aider`, or OpenAI/Anthropic SDKs) to Cloak's loopback gateway at `http://127.0.0.1:8742`.

## Modes

Each conversation locks its mode on turn 1. The **Active Guarantees** rail in the bottom-left of Chat shows your active Security Profile and only the protections actually enforced for that thread.

| Mode | Where inference runs | What leaves your Mac | Payment / auth | What can still link requests |
| --- | --- | --- | --- | --- |
| **1. Local** (`⌘1`) | On your Mac (`vmlx-swift` MLX, Metal `llama.cpp`, or loopback `127.0.0.1` servers) | Nothing during chat once weights are downloaded | Free · no account | Nothing leaves your Mac |
| **2. NEAR AI Gateway** (`⌘2`) | [NEAR AI Cloud](https://cloud.near.ai) (`Qwen3.8-27B`, Intel TDX + NVIDIA enclaves) | Prompt as written, E2EE v2 encrypted to the verified enclave (optional Tor) | Your NEAR AI Cloud API key | Your NEAR API key identifies your NEAR account |
| **3. Token Inference** (`⌘3`) | [Venice AI](https://venice.ai) or [Boundless](https://boundless.network) + Tempo | Locally rephrased user text over per-conversation Tor circuits (or optional direct HTTPS) | Local Base `USDC` (`x402`) / Venice key, or Tempo `USDC.e` (`MPP`) — fund via crypto or Stripe Link / Apple Pay | A reused wallet address, channel, or API key can link chats |
| **4. zkAPI Anon Inference** (`⌘4`) | [Open Anonymity](https://zkapi.openanonymity.ai) (`zkAPI`) over Tor | Locally rephrased user text over per-conversation Tor circuits | Fresh one-time ZK key per turn drawn from a reusable ETH deposit — no provider account or linked API key | Prompt content, thread history, and timing can still correlate requests |
| **5. Darkbloom Serving** | On your Mac via [Darkbloom](https://darkbloom.dev) ([EigenLayer](https://eigenlayer.xyz)) | Local Only stays on your Mac; Network + Local serves idle compute to Darkbloom | Earn payouts on idle Apple Silicon (`0%` platform cut, macOS 27+) | Linked `console.darkbloom.dev` provider account (Network + Local only) |

![Cloak Ecosystem Stack](docs/media/cloak-ecosystem-banner.png)

## Features

- **Fast local Apple Silicon inference + zero-duplicate server discovery** — pure-Swift MLX (`vmlx-swift` with RAM-only paged KV prefix caching and `Fast` / `Balanced` / `Deep` reasoning effort; `Inkling 2 Mini` runs ~74 tok/s on M4 Max in ~5.6 GB RAM), Metal `llama.cpp` GGUF tiers with optional 44 MB uncensored LoRA, and strictly loopback-only (`127.0.0.1`) auto-discovery for **Splash**, **TensorFold**, **mlx-serve**, **LM Studio**, **Ollama**, and **Darkbloom Local**
- **Saved Project Profiles** *(free in beta)* — keep each client or repository cleanly isolated with per-project approved Local folders, Privacy Shield private terms, preferred route, and Connected Apps model override, with 1-click switching in Chat's sidebar
- **Connected Apps (`CloakDoor`) with Privacy Shield & Spend Guardrails** — speaks both **OpenAI** (`/v1/chat/completions`, `/v1/models`) and **Anthropic** (`/v1/messages`, `/v1/messages/count_tokens`, `?beta=true`, SSE streaming, tool calling, Claude model aliases) across all 5 rails (`Local $0`, `NEAR TEE`, `Venice · Base`, `Boundless · Tempo`, `zkAPI Anon`); includes deterministic `< 2 ms` **Privacy Shield** (pre-send Secret Tripwire + reversible in-memory aliases for private terms, wallets, ENS names, paths, emails, and IPs — never rehydrating secrets or tool-call arguments), deterministic daily/per-request **Spend Guardrails**, 1-click **Test Connection**, and tailored setup presets for **Claude Code**, **OpenCode**, and **Goose**
- **On-device Local Voice** — native macOS 26 `SpeechAnalyzer` / `SpeechTranscriber` voice dictation and local speech synthesis with zero cloud audio uploads
- **Smart Private Router & card/crypto funding** — pick `Fast`, `Coding`, or `Deep Reasoning` across your ready Private Cloud rails without silent fallback to unconfigured providers, and fund self-custodial Base `USDC` or Ethereum `ETH` wallets via crypto transfer or Stripe Link / Apple Pay
- **Hardware-attested enclaves** — native Rust verifier (`cloak-near`) checks Intel TDX quotes (`dcap-qvl`), pinned `app_compose` measurements, and Intel Trust Authority NVIDIA GPU verdicts before E2EE v2 encryption
- **Local prompt rephrasing + per-conversation Tor + live Cover Traffic** — sandboxed `Qwen 3.5 9B` paraphrases user prose before cloud turns (preserving code, paths, URLs, and identifiers and failing closed on error), isolated Tor circuits per thread, and host-side Cover Traffic that toggles live with zero restart
- **Zero telemetry** — no analytics, no automatic crash reports, no Regents account, Sparkle system profiling disabled, and user-reviewed Redacted Diagnostic Reports in **Settings → Feedback**
- **Native macOS shell** — ChaCha20-Poly1305 encrypted chats, pure-Swift Markdown + LaTeX math, Liquid Glass menu bar panel (macOS 27+; classic menu on macOS 26), global Quick Prompt hotkey, Control Center & Desktop widgets, and a bundled `cloak` CLI

## Connected Apps (`CloakDoor`) examples

Generate a per-app key (`cloak-<64 hex>`) in **Settings → Connected Apps**, pick your billing rail (`Local ($0)`, `NEAR TEE`, `Venice · Base`, `Boundless · Tempo`, or `zkAPI Anon`), optionally configure **Privacy Shield** private terms and **Spend Guardrails**, and click **Test Connection**.

> **Privacy boundary:** `PrivacyShield` is deterministic (regex + custom Private Terms + active Project Profile terms) — it hard-blocks common secrets/keys and masks listed names/addresses, but does not yet run an on-device neural NER model to detect unfamiliar person/organization names in free prose. Local prompt rewriting paraphrases `role == "user"` prose on cloud rails (`Venice`, `Boundless`, `zkAPI`) and is skipped on `Local ($0)` and `NEAR TEE`.

**Claude Code (Anthropic Messages API):**

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:8742 \
ANTHROPIC_API_KEY=<cloak-app-key> \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
claude
```

**OpenAI-compatible clients (`OpenCode`, `Goose`, `Cursor`, `Cline`, `Aider`, SDKs):**

```sh
curl http://127.0.0.1:8742/v1/chat/completions \
  -H "Authorization: Bearer <cloak-app-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "anthropic/claude-sonnet-4-6",
    "messages": [{"role": "user", "content": "Review PR #418 for edge cases."}]
  }'
```

## Local Access & Offline Data

Everything in **Settings → Local Access** is off by default and wired **exclusively into Local Mode** (cloud modes, Connected Apps, and the Pi agent have zero code path to it):

- **Per-message file attachments** — click **Attach** or drag & drop PDFs (with automatic Vision OCR for scanned PDFs), screenshots/images (on-device Apple Vision OCR), `.docx`/`.rtf`/`.odt` documents, Markdown, and code files
- **Hermes-compatible memory & approved folders** — owner-only `USER.md`/`MEMORY.md` (optional `~/.hermes/memories/` sync) and read-only keyword search over approved folders (scoped to your active Project Profile when one is selected; always skips dotfiles, `.env*`, and private keys)
- **Opt-in macOS connectors** — read-only basic Mac info, Calendar (next 7 days), Reminders, and query-matched Contacts
- **Progressive Offline Data** — **Settings → Offline Data** downloads resumable Minimum → Maximum packs for Kiwix Library (`174 MB → 61 GB`), DevDocs (`15 MB → 240 MB`, 1-click linkable into Local Mode), CourtListener (`540 KB → 58.3 GB`), PubMed Central S3 CLI, and [Tinfoil Kit](https://github.com/tudor-city-ventures/tinfoil-kit)

## Inference Serving (Darkbloom)

On macOS 27+, **Settings → Inference Serving** integrates [Darkbloom](https://darkbloom.dev) ([Eigen Labs](https://github.com/Layr-Labs/d-inference)) with a unified 3-way **Serving Mode** (`Off` / `Local Only` / `Network + Local`):

- Verifies Darkbloom's signed binary (`Team SLDQ2GJ6TL`) before talking to its loopback-only control API
- Ranks Apple Silicon models that fit beside Cloak by live payout rate, displays a live RAM budget bar + Earn-to-Spend offset, and enforces **Mac Guardrails** (auto-pause on battery, high thermal pressure, or Quiet Hours)
- Respects your **Security Profile** (`Network + Local` is disabled under `Local Only + Downloads` and `Anon Private Cloud`, while `Local Only` remains available)

## Demos

- **[Local Mode · Inkling 2 Mini (Fast)](https://regents.sh/images/cloak/demos/demo-local-inkling.mp4)** — offline Apple Silicon MLX streaming & attachments
- **[NEAR AI Gateway + Trace Commons](https://regents.sh/images/cloak/demos/demo-near-traces.mp4)** — hardware TEE verification, E2EE v2, and local trace export
- **[Token Inference · Venice AI (Base USDC)](https://regents.sh/images/cloak/demos/demo-venice.mp4)** — Tor-routed Venice Private/TEE models & Base USDC `x402`
- **[Token Inference · Boundless + Tempo](https://regents.sh/images/cloak/demos/demo-boundless-tempo.mp4)** — Tempo `USDC.e` MPP payment channels & mid-chat switching
- **[zkAPI Anon Inference](https://regents.sh/images/cloak/demos/demo-zkapi.mp4)** — Ethereum Mainnet wallet, one-time ZK spend credentials, and deposit tiers
- **[Darkbloom Inference Serving](https://regents.sh/images/cloak/demos/demo-darkbloom.mp4)** — `Off` / `Local Only` / `Network + Local` serving & live monitor telemetry

## Build from source

Requires Apple Silicon, macOS 26+, Xcode / Swift 6.2+, Rust, `uv`, and Docker (for the Linux arm64 guest image):

```sh
uv run scripts/fetch_sources.py
llama-worker/install.sh
vmlx-worker/install.sh
guest/build.sh
host/build.sh
app/build.sh
swift test --package-path app
```

## Docs & Feedback

- **Wallet security & recovery (30-day zkAPI limit):** [docs/wallet-security.md](docs/wallet-security.md) · [regents.sh/docs/cloak/wallets](https://regents.sh/docs/cloak/wallets)
- **Architecture & codebase map:** [docs/tech-stack.md](docs/tech-stack.md) · **Integrations:** [INTEGRATIONS.md](INTEGRATIONS.md) · **Runbook:** [docs/dev-runbook.md](docs/dev-runbook.md) · **Licenses:** [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
- **Website & reference docs:** [regents.sh/cloak](https://regents.sh/cloak) · [regents.sh/docs/cloak/reference](https://regents.sh/docs/cloak/reference)
- **Issues & feedback:** [GitHub Issues](https://github.com/regents-ai/cloak/issues) · [Patchbay](https://regents.sh/patchbay/cloak) · [@regents_sh](https://x.com/regents_sh) · [build@regents.sh](mailto:build@regents.sh)
