# Venice in Token Inference

Venice (venice.ai) as a second provider inside Token Inference, beside
today's provider at Boundless. First pass, 20 November 2026: the client is
built and checked, and nothing is on screen yet. This is the plan for
joining it to the app once the four-mode work (decisions 23 to 25 in
`docs/plan.md`) is merged, and the size of verified encryption, which is not
built.

Sources, read anonymously and kept for this pass: Venice's documents at
docs.venice.ai (their `.md` pages), its API reference (`swagger.yaml`), its
public model list (`GET /api/v1/models`, fetched once), its terms (updated
8 June 2026) and privacy policy, github.com/veniceai/venice-cli and
github.com/veniceai/x402-client, and x402's legacy client (npm `x402`
1.2.1). Where a line below quotes them, the page is named.

## What a Venice chat is

- A Token Inference chat whose first message went to Venice. It keeps
  Venice, its model and that model's tier for the rest of its life
  (`Conversation.venice`). It never moves to another provider, model or
  tier: when Venice no longer lists the model as it was, the chat stops
  and says so.
- Its route is Token Inference's: each message is reworded on this Mac,
  sent from the guest through Tor on the conversation's own Tor identity,
  with cover traffic as the mode has it.
- It is paid one of two ways, chosen when it starts and kept:
  - **Key**: the owner's own Venice API key, Inference Only, kept in this
    Mac's keychain as NEAR's is.
  - **Wallet**: USDC on Base, with no Venice account, by Venice's x402
    route. Base only, no Solana, no automatic top-up.
- Models come from Venice's live list. No model name is written into the
  app. The picker lists the models Venice calls Private or TEE, and
  Anonymous ones only once the owner turns on All tiers.
- Venice's own system prompt is off, web search is off, and thinking is
  kept out of the answer.
- Agent tasks keep today's provider in this pass: the Agent switch shows
  only while Boundless is the provider.

## What is built

`app/Sources/CloakChat/Venice.swift` and
`app/Sources/CloakChat/VeniceWallet.swift`, with no caller in the app yet.

| Part | What it does |
| --- | --- |
| `Venice.models(transport:)` | `GET models?type=text`, no key, read strictly: each model's id, name, tier, whether it is offline or remapped, context and prices per million tokens |
| `VeniceTier` | Venice's tier in Venice's word (Anonymous, Private, TEE), with `about`, the tooltip, and `isVenicePrivate` for the picker's filter |
| `VeniceChat` | What a saved chat keeps: model and tier. `check(in:)` stops a chat whose model is not listed, is remapped, changed tier or is offline, before anything is sent |
| `Venice.account()` | Key: `GET api_keys/rate_limits` (balance in dollars and DIEM, whether the key may spend). Wallet: `GET x402/balance/{address}`, signed |
| `Venice.ask(_:turn:in:partial:)` | One message: a fresh list and the chat's check, then `POST chat/completions` streamed, partial text as it comes, the last usage chunk, an error mid-stream, cancellation |
| `VeniceStop` | Why a request stopped, as one of sixteen kinds, each with a title and a few words for the screen, and a `text` for the log made only from Cloak's own words, the status and known code names |
| `VeniceWallet.signIn(for:signer:now:nonce:)` | The `SIGN-IN-WITH-X` header for one URL, signed by the caller's signer |
| `Venice.topUpTerms()`, `topUp(_:on:by:)` | The top-up's challenge (402, Base USDC only), the EIP-3009 authorization to sign, and the payment header |
| `VeniceSigner` | Supplied by the caller: an address, a personal-sign function and a typed-data function. No key is held here |

The request body is exactly this, and nothing else (checked in
`app/Tests/CloakTests/VeniceTests.swift`):

```
{"messages":[...],"model":"<id>","stream":true,
 "venice_parameters":{"enable_web_search":"off","include_venice_system_prompt":false,"strip_thinking_response":true}}
```

`stream_options` is left out because "Every stream ends with a usage chunk
before `[DONE]`, even when `stream_options.include_usage` is false"
(`openai-migration.md`). Unknown top-level fields are refused with 400 there,
but unknown `venice_parameters` keys are ignored, so each key is spelled as
the API reference has it.

## Transport

NEAR is the precedent for the key and the Settings pane, not for the route.
NEAR's helper runs on the Mac and leaves through the Mac's own tor socket
(`NearRoute.tor`, `Supervisor.torSocket`). Token Inference leaves from the
guest's sender through the guest's Tor port, and Venice keeps that route, as
the chief chose. So the transport is a new sender request, not NEAR's
helper.

### Guest: `guest/sender/src/lib.rs`

Three new requests, beside `create`, `wallet`, `models`, `send`, `close`
and `withdraw`:

```rust
/// Venice's API root. The sender reaches nothing else for Venice.
const VENICE: &str = "https://api.venice.ai/api/v1/";
/// Base's public RPC, for the Venice wallet's USDC.
const BASE_RPC: &str = "https://mainnet.base.org";
/// USDC on Base.
const BASE_USDC: &str = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

/// One request to Venice through Tor as `identity`, as the Mac built it.
#[derive(Deserialize)]
pub struct Venice {
    identity: String,
    method: VeniceMethod, // "GET" or "POST", nothing else
    path: String,         // after VENICE, such as "chat/completions"
    headers: BTreeMap<String, String>,
    body: Option<String>, // JSON text
}

enum Request {
    // ...
    Venice(Venice),
    /// EIP-191 signature of `message` by `key`. No network.
    VeniceSign { key: B256, message: String },
    /// EIP-712 signature of `typed` (eth_signTypedData_v4 JSON) by `key`. No network.
    VeniceTyped { key: B256, typed: alloy::dyn_abi::TypedData },
    /// The address's USDC on Base, read through Tor on a fresh identity.
    VeniceFunds { address: Address },
}
```

What `Venice` checks before anything leaves:

- `identity` is 64 hex digits, as `send`'s is;
- `VENICE` joined with `path` parses as `https` with host `api.venice.ai`
  and a path under `/api/v1/`; anything else stops with `failed` and sends
  nothing;
- header names are only `authorization`, `sign-in-with-x`,
  `payment-signature` and `content-type`. The client is `client(identity)`,
  which adds no header of its own, follows no redirect and takes no proxy
  from the environment.

The signing requests use alloy's `PrivateKeySigner` as `send` does:
`sign_message(message.as_bytes())` and
`sign_hash(&typed.eip712_signing_hash()?)`, each answered as 0x-hex of
r, s and v. `VeniceFunds` calls `balanceOf` on `BASE_USDC` through an alloy
provider on `BASE_RPC`, built as `rpc` is for Tempo.

**Frames.** A Venice answer streams. After the request, the sender writes
`H` once, the status and every response header with lower-case names, as
JSON; then `P` frames, the body's bytes as they arrive, each at most
`MAX_FRAME`; then `A`, `{"ok":{}}` or `{"stop":...}`. A stop before `H` is
`tor_down` when Tor could not connect (nothing sent) and `failed`
otherwise. The other new requests answer with one `A`, as today. A failed
frame write means the Mac has gone: the sender drops the response, which
closes the Tor stream, and Venice stops answering. `REQUEST_LIMIT` (180
seconds, connect to last byte) holds for Venice too.

### Host: `host/Sources/CloakHost/Sender.swift`

`Sender.stream(_ socket:, request:) -> AsyncThrowingStream<Sender.Piece, any Error>`,
built as `Runner.run` is: `Piece` is `.head(status, headers)`, `.body(Data)`
or `.end(Data)` (the `A` payload). Ending the stream first, as a consumer that
stops does, shuts the socket (`onTermination`). `exchange` stays as it is
for the one-answer requests. No change to the relay or to tor: TorRelay has
no list of destinations, and the guest's Tor port reaches any host.

### App

- `Supervisor.swift` (after the merge): `public func venice(_ request: Data) -> AsyncThrowingStream<Sender.Piece, any Error>`,
  refused unless Running, as `exchange` and `run` are. CloakSupervisor does
  not import CloakChat, so it carries bytes.
- `app/Sources/RegentsCloak/VeniceMode.swift` (new) turns a `VeniceRequest`
  into the `venice` request's JSON for the conversation's identity, and the
  pieces into a `VeniceResponse`: `.head` gives status and headers, `.body`
  feeds `body`, `.end` with `ok` finishes it, and a stop finishes it with an
  error (`VeniceUnreachable(sent:)`: false for `tor_down`, true otherwise).
  The model list goes on the conversation's own identity, since the chat
  follows it on the same circuit.

## Which wallet

The app's signing code is the guest's: the sender's `create` makes a key
with alloy, the Mac keeps it in the keychain (`WalletKeychain`, service
`sh.regents.cloak.wallet`) and hands it back as hex for each request that
signs (`Remote.hexKey`). Venice's wallet signs with the same code, through
`venice_sign` and `venice_typed`.

The sounder choice is a **separate key** for Venice, made by the same
`create` and kept under its own keychain service
(`sh.regents.cloak.venice-wallet`):

- An address is the same on every EVM network. One key on Tempo and Base
  would show, to anyone reading both networks, that the Boundless deposits
  and the Venice top-ups have one owner. Venice also records the wallet
  address it is paid from (privacy policy).
- Token Inference's standing sentence says one wallet links each
  provider's chats. With one key it would also link the two providers'
  chats to each other.
- The tokens differ (USDC.e on Tempo, USDC on Base); two addresses keep
  each sheet's "send here" to one token.
- The cost: two addresses to fund, and USDC sent to the wrong one waits at
  an address Cloak does not watch on that network. The sheet names the
  network and token beside each address.

The choice is Sean's; the plan below assumes the separate key.

## Changes, file by file

| File | Change |
| --- | --- |
| `app/Sources/CloakChat/Conversation.swift` | `public var venice: VeniceChat?`, set with the first message and never changed; `isVenice`. Absent in every other chat |
| `app/Sources/CloakChat/Venice.swift` | `VeniceChat` gains `pays` (`key` or `wallet`), so a chat keeps how it pays; `VeniceKeychain` (service `sh.regents.cloak.venice`) as `NearKeychain` is; `VeniceWalletKeychain` (`sh.regents.cloak.venice-wallet`) as `WalletKeychain` is |
| `app/Sources/CloakChat/Remote.swift` | `veniceSign`, `veniceTyped` and `veniceFunds` over `Exchange`, as `close` is built; the signer for `VeniceAuth.wallet` is made from the first two |
| `app/Sources/RegentsCloak/VeniceMode.swift` (new) | The transport above; the list (`models`, `listStop`); the account (`account`, `accountStop`); one message's state (below); the wallet's top-up state (below); `hasKey`, `save`, `remove` as `NearMode` has them |
| `app/Sources/RegentsCloak/AppSettings.swift` | `provider` (Boundless or Venice) for new Token Inference chats; `venicePays` (Key or Wallet, default Key); `veniceModel` (an id, or nil); `veniceAllTiers` (false). Restore Defaults puts each back |
| `app/Sources/RegentsCloak/SettingsView.swift` | A Venice pane, below |
| `app/Sources/RegentsCloak/Chat.swift` | `submit` sends a Venice chat through `VeniceMode`: the chat's own `pays`, `model` and `tier`, its identity from `identities`, partial text into the card. `Chat.sending[turn]` holds it while under way |
| `app/Sources/RegentsCloak/ChatView.swift` | The tier capsule; the standing sentence; Send's reasons; the stops' words; Stop while answering |
| `app/Sources/RegentsCloak/WalletView.swift` | The provider choice and Venice's sections, below |
| The Modes page (the four-mode work's file) | Token Inference's column, below |
| `guest/sender/src/lib.rs`, `host/Sources/CloakHost/Sender.swift`, `app/Sources/CloakSupervisor/Supervisor.swift` | The transport above |
| `docs/state-machines.md` | A section 9d from "States" below; section 7a gains `api.venice.ai` and `mainnet.base.org` as the sender's destinations |
| `README.md` | Token Inference's paragraph gains Venice, its two ways to pay and what Venice sees |

## Settings: the Venice pane

Built as `NearPane` is (grouped form, `Row` with a note, symbol buttons).
Sidebar: **Venice**, symbol `water.waves`, after NEAR.

| Row | Control | Note |
| --- | --- | --- |
| Key | A secure field, placeholder "Venice key", and Save; once saved, "Saved" with Replace (`pencil`) and Remove (`trash`) | "Your Inference Only key from Venice. You can create one at venice.ai/settings/api. It pays for Venice chats that pay with a key, so Venice can connect those chats to your account. Cloak keeps it in this Mac's keychain, and it can't be viewed here after you save it." |
| All tiers | A switch, off | "Off, Cloak lists only the models Venice calls Private or TEE. On, it also lists those Venice calls Anonymous, whose own companies can read your messages." |

- A keychain refusal shows "The keychain said no. Try again." under the
  row, in red, as NEAR's does.
- Remove asks first: "Remove key?", "Venice chats that pay with a key can't
  send until you save a key again.", with Remove (destructive) and Cancel.
- The key is not checked on Save. The wallet sheet's balance is the check,
  and needs Cloak running, as everything Venice does.
- No Tor switch: Venice always goes through Tor, as Token Inference does.

## The wallet sheet

The sheet keeps its frame. For a Token Inference chat it gains a
**Provider** picker at the top, Boundless or Venice (`AppSettings.provider`,
for new chats). For a Venice chat, the picker shows that chat's provider and
cannot change it. With Venice chosen, the Tempo sections stay below,
unchanged, and two sections come first:

**Venice**

| Row | Contents |
| --- | --- |
| Pay with | A segmented picker, Key or Wallet (`venicePays`, for new chats). Help: "How new Venice chats pay. Each chat keeps the way it started with." |
| Key, when Key | "Saved" or "None", with the Settings symbol, as NEAR's row is |
| Balance, when Key | The key's balance in dollars, then "DIEM" and its balance when it has any. Help on DIEM: "Venice's DIEM allowance on this key." |
| Under them, when Key | "Paid from your Venice account at [venice.ai/settings/api](https://venice.ai/settings/api)." |
| Address, when Wallet | The Venice wallet's address with Copy and the QR button, or, before it exists, "Cloak makes a second wallet for Venice, apart from the Tempo one." and **Create** |
| Token, when Wallet | "USDC on Base" |
| On hand, when Wallet | The address's USDC on Base |
| Credit, when Wallet | Venice's balance for the address |
| Amount, when Wallet | A dollar field, starting at Venice's suggested top-up, and **Add**. Under it: "Venice's least is $5. Venice keeps what you add; it can't be sent back." The amount is the challenge's (`VeniceTopUpTerms.least`; $5 in `x402-top-up.md`), and the second sentence is terms 6.5: credits are "non-transferable" and "non-refundable" |

**Models**: the Venice model picker, replacing Boundless's while Venice is
chosen. Each row: the model's name, its tier as a capsule in Venice's word
(Anonymous, Private, TEE) with the tier's `about` as help, and its prices,
"in | out" as today. Only `isVenicePrivate` models unless All tiers is on.
A model that is offline is dimmed and cannot be chosen, its help "Offline
at Venice."

Buttons, under the money rule:

- **Add** is never held back by the page. It is disabled only when the
  address's USDC on Base, read at the latest block, is below the amount:
  "Needs $2.10 more on Base." beside it. A read that fails enables it. Each
  press signs and sends a new authorization; two presses pay twice.
- **Create** and **Add** are off while Cloak is not running, as today's
  wallet buttons are, since the key signs in the guest: "Start Cloak to use
  the wallet."
- A refused top-up shows the stop's words ("Venice did not take the
  payment. Check the wallet's USDC on Base, then try again.") beside Add.
- Added: "Added $7.50." and the new credit.

## Chat

- The mode pill stays Token Inference. Beside it, a Venice chat carries a
  capsule with "Venice" and the tier, such as "Venice TEE", its help the
  tier's `about`, which begins "Venice's word for this model."
- The standing sentence for a Venice chat: "Venice can link your chats,
  because one key or one wallet pays for all of them."
- Send is off only where sending is certain to stop, with the reason beside
  it and a button to where it is fixed:
  - Cloak not running: "Start Cloak to send."
  - A key chat with no key kept: "Save your Venice key in Settings.", with
    Open Settings.
  - A wallet chat with no Venice wallet: "Create the Venice wallet first.",
    with Open Wallet.
  - A new chat with no model chosen: "Choose a model in the Wallet.", with
    Open Wallet.
  No balance does not hold Send back: Venice answers 402 and the card says
  so.
- A message under way shows its text as it comes and a Stop button (and
  ⌘.). Stop cancels the request: whatever Venice charged so far stays
  charged.
- A stop shows its title and words from `VeniceStop`. Model gone and Tier
  changed offer no Send Again, since both are certain to stop again: the
  card says to start a new chat.

## The Modes page

Token Inference's column, added to what the four-mode work writes:

- Paid with: "USDC.e on Tempo, or at Venice with your own key or USDC on
  Base."
- Its info line: "Venice lists each model with its own tier: Anonymous,
  Private or TEE. Cloak shows Venice's word and cannot check it."

## Every on-screen word

| Where | Words |
| --- | --- |
| Settings sidebar | Venice |
| Settings rows | Key, All tiers, Saved, Save, Replace, Remove |
| Key field | Venice key |
| Notes | The two notes above |
| Alert | Remove key? / Venice chats that pay with a key can't send until you save a key again. / Remove / Cancel |
| Keychain | The keychain said no. Try again. |
| Sheet | Provider, Boundless, Venice, Pay with, Key, Wallet, Balance, DIEM, Address, Token, USDC on Base, On hand, Credit, Amount, Add, Create, None, Models |
| Sheet lines (amounts as read) | How new Venice chats pay. Each chat keeps the way it started with. / Venice's DIEM allowance on this key. / Paid from your Venice account at venice.ai/settings/api. / Cloak makes a second wallet for Venice, apart from the Tempo one. / Venice's least is $5. Venice keeps what you add; it can't be sent back. / Needs $2.10 more on Base. / Start Cloak to use the wallet. / Added $7.50. / Offline at Venice. |
| List | Start Cloak to see Venice's models. / Cloak couldn't read Venice's models. / Try Again |
| Tiers | Anonymous, Private, TEE, each with its `about` (`VeniceTier.about`) |
| Chat | Venice Anonymous, Venice Private, Venice TEE / Venice can link your chats, because one key or one wallet pays for all of them. / Start Cloak to send. / Save your Venice key in Settings. / Create the Venice wallet first. / Choose a model in the Wallet. / Open Settings, Open Wallet, Stop |
| Stops | The sixteen titles and lines in `VeniceStop.Kind` |
| Modes page | The two lines above |

The tier tooltips, as built:

- Anonymous: "Venice's word for this model. Venice sends your messages to
  the model's own company without your Venice account. That company can
  read them and may keep them."
- Private: "Venice's word for this model. Venice says the model keeps
  nothing once it answers, by contract. Venice and the model's host can
  still read your messages, and Cloak cannot check what they keep."
- TEE: "Venice's word for this model. Venice says the model runs in sealed
  hardware that can prove what it runs, and keeps nothing once it answers.
  Cloak does not check that proof, and Venice can still read your messages
  on their way in."

## States

Section 9d of `docs/state-machines.md`, once joined. One message in a Venice
chat, held as one value per turn, `VeniceMode.Turn`, in memory only:

```
written --Send--> listing (a fresh list through the guest)
listing --model gone, remapped, other tier or offline--> stopped (sent: false)
listing --list unread--> stopped (unreachable or failed, sent: false)
listing --listed as the chat began--> answering (text so far)
answering --[DONE] after stop or length, text not blank--> answered (Turn.answer)
answering --a chunk names another model--> stopped (otherModel, sent: true, text dropped)
answering --error event mid-stream--> stopped (busy, tooLong or failed, sent: true)
answering --stream ends before [DONE]--> stopped (failed, sent: true)
answering --Stop, ⌘., or the chat closes--> stopped (cancelled, sent: true)
answering --Cloak pauses, stops or quits--> stopped (unreachable, sent: true)
stopped --Send Again, on the newest message, not gone or tierChanged--> listing
```

A wallet chat signs twice per message: the list needs no signature, then
the chat's sign-in is signed in the guest just before the POST. A sign-in
the guest cannot make stops with `signing`, nothing sent. A message saved
without an answer shows "Not answered" after a relaunch, as Local Llama's
does.

The wallet's top-up, one value, `VeniceMode.TopUp`:

```
none (no Venice wallet) --Create--> idle
idle --Add--> asking (bare POST, Venice's challenge, Base USDC only)
asking --no Base USDC entry, or unreadable--> refused (failed, nothing signed)
asking --challenge read--> signing (EIP-3009 authorization in the guest)
signing --guest cannot sign--> refused (signing, nothing sent)
signing --signed--> paying (POST with PAYMENT-SIGNATURE)
paying --200--> added (amount, new credit) --> idle
paying --400, 401 or 402--> refused (paymentRefused, sent: true)
paying --no answer--> refused (unreachable, sent: true: it may have paid)
```

Each press starts its own run; a second Add while one is under way starts
a second, and both may pay.

## Costs and limits

- The list is about 180 KB for every message (148 text models on
  20 November: 71 Anonymous, 63 Private, 14 TEE). Through Tor that is a
  second or two. It is the proof before sending that the model is still
  listed as it was; it is not cached.
- After sending, a model is held to the chat only by Venice's echo of its
  id in each chunk. The model field "may also be a model trait, or a model
  compatibility mapping" (`chat-completions.md`); Cloak sends only ids from
  the list. `deprecation.autoRemap` (`models-list.md`: "Venice may
  automatically remap API requests for this model ID to replacementModelId
  instead of returning an error") is why a remapped model counts as gone.
- An Admin key would work as an Inference Only one does, and can also "manage
  API keys" and read billing (`generating-api-key.md`). Cloak cannot tell
  them apart from the key; the note asks for Inference Only.
- The key crosses into the guest for each request, as the Tempo wallet's
  key does. NEAR's never leaves the Mac.

## Verified encryption

Not built. What it would take, from Venice's guide
(`tee-e2ee-models.md`) and its CLI.

### What Venice's protocol asks of a client

1. A fresh secp256k1 key pair per session.
2. `GET /api/v1/tee/attestation?model=…&nonce=…` with a 32-byte nonce
   ("TEE providers require exactly 32 bytes"). The answer carries
   `verified`, `nonce`, `model`, `tee_provider`, `intel_quote` (base64 TDX
   quote), `nvidia_payload`, `signing_key` and `signing_address`.
3. Checks: the nonce matches, not debug mode, the quote valid, and the
   signing key bound to the quote: "The signing key should be bound to the
   TDX REPORTDATA field." The CLI's binding is the first 20 bytes of
   REPORTDATA equal to the key's Ethereum address (`e2ee.ts`,
   `verifyKeyBinding`).
4. Each `user` and `system` message's content sealed on its own: ECDH on
   secp256k1 with the model's key, HKDF-SHA256 with info
   `ecdsa_encryption`, AES-256-GCM with a 12-byte nonce, sent as hex of the
   ephemeral public key (65 bytes), the nonce and the ciphertext with its
   tag.
5. The headers `X-Venice-TEE-Client-Pub-Key`, `X-Venice-TEE-Model-Pub-Key`
   and `X-Venice-TEE-Signing-Algo`.
6. Each streamed piece decrypted with the session key; then, optionally,
   `GET /api/v1/tee/signature?model=…&request_id=…` and the signature
   checked against `signing_address`.

### What Venice's own CLI leaves unchecked

- `cli-tee.ts`: `ATTESTATION_SCOPE_NOTE = 'The Intel TDX quote signature and enclave measurements are not verified client-side.'`
- `cli-commands-tee.ts`: "The CLI does not take the signer from the
  server's attestation, because it does not verify the Intel TDX quote
  signature or enclave measurements."
- `cli-chat.ts`, in TEE mode: "Server attestation report passed the CLI's
  consistency checks; it is not bound to this request", and "TEE mode: not
  end-to-end encrypted; Venice's proxy can read the prompt".
- The hardware verdicts it accepts are Venice's own:
  `serverVerification.nonceBinding.bound`, `tdx.valid` and `nvidia.valid`
  (`cli-tee.ts`, `evaluateTEEAttestationPolicy`).
- What it does check itself: the nonce, debug mode, the key's binding to
  REPORTDATA, and the reported address against the key.
- Venice's guide asks for more than its CLI does: "Don't just trust the
  `verified: true` response. Parse the Intel TDX quote client-side and
  verify the measurements match expected values." It publishes no expected
  values, and does not say who runs the hardware (`tee_provider` is a
  name in the answer).

### What NEAR's check already has

`guest/near/` (the `cloak-near` helper):

- `verify_intel`: the TDX quote through `dcap-qvl` (Intel's certificate
  chains, revocation, the quote's signature, collateral, an `UpToDate`
  verdict, debug refused), REPORTDATA's binding to a key and a nonce, the
  event log replayed to RTMR3, and pinned MRTD, RTMR0 to 2 and MRCONFIGID.
  The quote checking is reusable as it is. The binding differs (Venice
  binds an address in the first 20 bytes, NEAR a hash of key and TLS
  fingerprint), and the pins cannot be reused: Venice's measurements are
  not published.
- `verify_gpu`: NVIDIA's evidence through Intel Trust Authority's tokens,
  fetched from NEAR. Venice passes `nvidia_payload` for the client to send
  to NVIDIA's own service (`nras.attestation.nvidia.com`, as the CLI names
  it). The token checking is reusable; the fetch is new.
- `e2ee.rs`: NEAR's sealing per field (X25519, HKDF-SHA256 with
  `ed25519_encryption`, XChaCha20-Poly1305) and its check against NEAR's
  published vectors. Venice's needs secp256k1 and AES-256-GCM instead; the
  shape (seal each field, hex of key, nonce and ciphertext) is the same.
- Its proof freshness, the shield beside the Tor pill and the check's
  states (section 9b) would serve Venice as they are.

### What stays readable to Venice in a sealed multi-turn chat

- Every earlier answer: "Only `user` and `system` role messages need
  encryption", and other roles go as they are. The CLI sends earlier
  answers back in the clear (`cli-chat.ts`, where the reply is pushed to
  the history unsealed). So from the second message on, Venice reads every
  answer the model gave.
- Tools: "Tool definitions are not encrypted." Tool calls and results are
  `assistant` and `tool` messages, so they go as they are.
- Stop sequences, the model id, the parameters and the token counts.
- Message lengths, timing and the Tor exit.

Cloak could seal earlier answers by sending each as part of a sealed
`user` message instead of an `assistant` one. That changes the prompt the
model sees, and Venice's guide does not cover it.

### Size

- On the Mac or in the helper: secp256k1 ECDH, HKDF, AES-GCM and the hex
  framing; streaming decryption; the attestation fetch and checks; the
  signature check; checks against vectors from Venice's guide. About the
  size of `e2ee.rs` plus a third of `verify.rs`.
- The hard part is not code: Cloak would need measurements to pin, which
  only Venice or its hardware host can give, and until then the quote
  shows real Intel hardware running something unknown. Without pins this
  is Venice's CLI's level of check plus the quote's own signature.
- E2EE models answer plain requests too: the CLI's `--no-e2ee` "uses TEE
  mode, so Venice's proxy can read the prompt" (`cli-chat.ts`). That is
  how this pass sends to them. Every model listed as TEE on 20 November is
  also an E2EE model (ids starting `e2ee-`).
