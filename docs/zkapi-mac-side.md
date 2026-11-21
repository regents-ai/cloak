# zkAPI build steps 6 and 9: design for a worker

Drawn by a planning helper on 20 November 2026 from the source, for the chief. Not yet checked line by line; the chief's choices on its section 7 are in plan.md. Sean's decisions 23 and 24 of the same day change it: a withdrawal goes to the guest's own funding address (question 2, option c), and the Tempo wallet stays as a mode of its own, so section 5's deletions of the sender, its host half and the Tempo wallet parts do not happen, and question 5 falls away.

Nothing was changed, and no code from the mainnet tree was run. Everything below is read from source; the last section before the file list says what I could not determine.

Repository root: `/Users/sean/Documents/regent/repos/cloak`. Daemon files are under `reference/src/zkapi-mainnet/zkapi-clientd/`, written below as `daemon:`.

## 0. Five findings that shape the design

1. **`cloak-pay` carries money calls since step 6's guest half (21 November 2026).** When this was drawn, `newPay` built the API with no admin handler, no `FundingHandler` and no companion. Step 5 added those and the start at boot; step 6 added the `C`, `V` and `H` frames (`guest/pay/zz_cloak_pay.go`) and the chain read (`guest/pay/zz_cloak_chain.go`).
2. **No endpoint of the pinned daemon carries the expiry date.** `AddressFundingStatus` (`daemon:internal/zkapi/address_funding.go:24-41`) and `AddressWithdrawalStatus` (`daemon:internal/zkapi/address_withdrawal.go:22-40`) have no such field, and `WalletReadiness` (`daemon:internal/zkapi/readiness.go:12-17`) drops it. It exists only as `note.expiry_ts` in the companion's `/wallet/status`, reachable in-process through `Client.WalletStatus` (`daemon:internal/zkapi/client.go:543-548`). The overlay must add its own read.
3. **A pause blocks withdrawal but not the taking.** In `reference/src/zkapi-walletd-protocol/contracts/src/ZkApiVault.sol`, `deposit` (98-128) and `mutualClose` (130-141) are `whenNotPaused`; `claimExpired` (223-233) is not, and has no access control. A deposit that expires during a pause can be taken while its owner cannot withdraw.
4. **Any key reuse window breaks step 3's hold as written.** `WaitSettled` in `guest/pay/client.patch` settles the outstanding key before each request, so a shared key would never be reused without rewriting it.
5. **The old wallet key is the only copy.** The Development wallet's key lives only in the login keychain (`app/Sources/CloakChat/Remote.swift:17-68`), and the app has no way to send its balance anywhere. Cutover must not strand money (question 5 in section 7).

## 1. The Mac-side payer

### Who owns each fact

| Fact | Owner | Never held by |
|---|---|---|
| Note exists, `depositAmount`, `expiryTs`, status, vault `paused`, funding address's ETH, receipts | The chain | — |
| Ethereum key, note secret, private balance, pending journal, saved quotes, saved withdrawal destination, management token, provider keys (memory only) | `cloak-pay`, as user `pay` on the encrypted disk | The Mac, the agent |
| Order of requests, each conversation's Tor identity, rewording, the owner's presses, time limits | The Mac app | `cloak-pay` |
| What the sheet shows | The Mac app, as a mirror read fresh each time | — |

The Mac writes two payment facts to disk, both in `AppSettings`: `depositExpires`, the expiry, so it can warn while Cloak is paused and the guest is down, cleared when there is no note; and `vModel`, the model the owner picked in Wallet, kept only when they pick. The expiry is new saved data, kept plainly; whether it should be sealed like `agents` is still open.

### States

One named value, as `docs/state-machines.md:893-897` asks. It is computed from one read and never stored.

| State | Entered when | Source |
|---|---|---|
| `unread` | Cloak is not Running, or nothing read yet | Supervisor phase |
| `none` | `has_note` false, funding `phase` one of `ready`, `waiting_funds`, `active`, `withdrawal_pending` or `return_pending`, and withdrawal `phase` one of `no_note`, `ready` or `complete` | view frame; `GET /admin/funding/address`; `GET /admin/withdrawal` |
| `depositing(stage)` | funding `phase` is `approval_pending`, `deposit_pending` or `confirming`; `deposit_stage` is `pending` (also when absent), `fee_wait`, `finalizing` or `activating` | `daemon:internal/zkapi/address_funding.go:124-168` |
| `ready` | `has_note`, the chain's note not `closed`, and not `settling` | view frame; `GET /admin/withdrawal` |
| `settling` | `pending_request` true and no request of ours is being sent | view frame |
| `withdrawing(phase)` | withdrawal `phase` is `quoted`, `waiting_funds`, `withdrawal_pending` or `confirming`, or `waiting_settlement` with a saved destination (without one, it is only the last request settling) | `daemon:internal/zkapi/address_withdrawal.go:124-181` |
| `taken` | `has_note`, and the chain says the note is `closed`, with no withdrawal of ours under way | view frame, chain part |
| `failed(fault)` | any funding phase, deposit stage or withdrawal phase not named above, `reverted`, `legacy_recovery`, `recovery_required` and `failed_finalizing` among them | both status calls |

`Payer.state(view:funding:withdrawal:sending:)` checks the funding phase first, then the withdrawal phase, then the note, in that order. A `failed` state makes no follow call.

Two things sit beside it rather than inside it:

- **Expiry band**: `far`, `near` (inside the warning period) or `due` (the day has passed and the note is still `Active`). It applies to `ready`, `settling` and `withdrawing`.
- **A request in turn** belongs to the queue, not the deposit. Each request is `waiting`, `held` or `sending`.

An unknown phase is `failed`, with no call made and no guess.

### Calls over the host's existing channel

The channel is `Guest.connect(to:)` at `host/Sources/CloakHost/Guest.swift:112-125`, to vsock port 8021, one exchange per connection, in the existing frames: a kind byte, the payload's length as four bytes, big-endian, then the payload, at most 16 MiB (`host/Sources/CloakHost/Pay.swift`). Every payload is a JSON object. The host writes one frame and reads until `A`; for `R` it also takes `H`, and any other frame, or `H` after `C` or `V`, ends the exchange as a failure. Three frame kinds are added to the existing `R` and `A`:

| Frame | Byte | Direction | Payload | Takes a turn |
|---|---|---|---|---|
| `R` (exists) | `0x52` | host to guest | `{"identity": "<64 hex>", "body": "<the chat request, OpenAI's shape, as a JSON text>"}` | Yes |
| `H` (new) | `0x48` | guest to host | `{"held": true}` once, when the hold first finds an earlier settlement unfinished; then `{"held": false}` once, when the hold ends, just before the request's key is asked for. No `H` comes for a request that was not held | — |
| `C` (new) | `0x43` | host to guest | `{"method": "GET" or "POST", "path": "<allowlisted>", "body": "<the route's JSON body as a JSON text, or \"\" for none>"}`, called in-process | No |
| `V` (new) | `0x56` | host to guest | `{"chain": true or false}` | No |
| `A` (exists) | `0x41` | guest to host | `{"status": <HTTP status>, "body": "<the route's body as text>"}` | — |

An `R` body holds `model`, `messages` and `"stream": false`: each user message as it was sent (reworded, unless its owner pressed Send Original Text or ticked Never reword), after the turns sent and answered before. A reworded message's original is never in it. `C` bodies are written by the Mac with the keys below, in snake case; answers are read with snake case turned to camel case (`JSONDecoder.pay`).

`C` goes through the same in-process `p.api.ServeHTTP` that a chat request uses (`serveAPI` in `zz_cloak_pay.go`). `cloak-pay` adds the bearer key and `X-OA-Management-Token` itself, which the daemon requires at `daemon:internal/server/server.go:108-118`, and `Content-Type: application/json` on a POST. Neither the key nor the token is ever in a frame. Anything outside the allowlist, by exact method and path with no query, is answered 404 without reaching the daemon; a `C` or `V` frame that does not read is answered 400.

The allowlist, all routed in `daemon:internal/zkapi/funding_admin.go` (`ServeAdminHTTP`, line 14):

| Need | Endpoint | Line | Body | Returns |
|---|---|---|---|---|
| Address and funding state | `GET /admin/funding/address` | 28 | — | `AddressFundingStatus`; makes the key on first call |
| Deposit: prepare | `POST /admin/funding/quote` | 42 | `{"micro_usd": n}` | `AddressPaymentQuote` (`address_quote.go:17-50`) |
| Deposit: sign | `POST /admin/funding/approve` | 56 | `{"quote_id"}` | `AddressFundingStatus` |
| Deposit: follow | `POST /admin/funding/deposit` | 94 | `{"amount"}` (the saved amount) | `AddressFundingStatus` |
| Balance and withdrawal state | `GET /admin/withdrawal` | 30 | — | `AddressWithdrawalStatus` (`private_balance`, `note_id`, `phase`, `eth_balance`) |
| Withdraw: prepare | `POST /admin/withdrawal/quote` | 74 | `{"destination","note_id"}` (`note_id` required, 82) | quote |
| Withdraw: sign | `POST /admin/withdrawal/approve` | 56 | `{"quote_id"}` | `AddressWithdrawalStatus` |
| Withdraw: follow | `POST /admin/withdrawal` | 74 | same destination and note | `AddressWithdrawalStatus` |
| Leftover ETH | `GET /admin/return` | 32 | — | `AddressReturnStatus` |
| Send Out: prepare | `POST /admin/return/quote` | 105 | `{"destination","amount_wei": ""}`; an empty amount sends all of it (`address_return.go`, near 118); the destination must differ from the funding address, or the daemon refuses | quote |
| Send Out: sign | `POST /admin/return/approve` | 56 | `{"quote_id"}` | `AddressReturnStatus` |
| Send Out: follow | `POST /admin/return` | 113 | none | `AddressReturnStatus` |
| A saved quote | `GET /admin/{funding,withdrawal,return}/quote` | 34 | — | quote or none |
| Models | `GET /v1/models` | `server.go:120` | — | ids with `oa_request_limit_micro_usd` (`model_budget.go:174-210`) |

Facts about these calls that the Mac must respect:

- POST needs `Content-Type: application/json` (19-23) and a body under 1024 bytes (24). Errors come back as 502 `{"error": "<message>"}` (128-131).
- A quote lives 30 seconds, its `expires_at` in milliseconds since 1970 (`address_quote.go:253`), and an approve of a stale or replaced quote fails closed (`checkedAddressQuote`, `address_quote.go:200-207`).
- Each admin call has a 10-minute limit (line 17).
- The follow call cannot sign. For native ETH, signing without an approved quote is refused (`address_funding.go:646-649`); a saved transaction is only re-sent as identical bytes (`address_funding.go:323-337`).
- The Mac may call follow on its own only in the phases listed below, and always with the saved amount. With no deposit saved, the same call would write an amount into the record (`address_funding.go:264`).

Withdraw's destination is always the funding address itself (decision 23a): the Mac quotes `{"destination": <the address GET /admin/funding/address gave>, "note_id": <the withdrawal status's note_id>}` and nothing else. The Mac's follow calls are exactly three, each only from what the last read saved:

- `POST /admin/funding/deposit` `{"amount": <funding status's amount>}` while the funding `phase` is `deposit_pending` or `confirming` and an amount is saved.
- `POST /admin/withdrawal` `{"destination", "note_id"}`, both from the withdrawal status, while its `phase` is `withdrawal_pending` or `confirming`.
- `POST /admin/return` while the return `phase` is `return_pending`.

**Expiry and settlement status** come from `V`, since the admin API has neither in usable form. Its answer is exactly:

```json
{
  "wallet": {
    "has_note": true,
    "pending_request": false,
    "note": { "note_id": 7, "expiry_ts": 1795000000 }
  },
  "chain": {
    "block": 23000000,
    "time": 1794000000,
    "paused": false,
    "balance_wei": "1000000000000000",
    "note": { "status": "active", "expiry_ts": 1795000000 }
  }
}
```

- `wallet` is from `Client.WalletStatus`; `wallet.note` is absent without a note.
- `chain` is present only for `{"chain": true}`, and read at one block, the one `eth_getBlockByNumber "latest"` gave: its number and time, vault `paused()`, `notes(noteId)` as `chain.note` (absent without a note; `status` is `uninitialized`, `active`, `pending_withdrawal` or `closed`), and the funding address's balance in wei, as a decimal string. A `V` whose wallet or chain read fails answers 502 `{"error": "<message>"}`, with no part of the deposit; the Mac then blocks no button on the chain.
- The chain read first checks the RPC's network (`eth_chainId`), as every read of the funding address does, and reads that address as `GET /admin/funding/address` does, so the first `V` with the chain makes the payer's key, as that call would.

The chain read is a new overlay file, `guest/pay/zz_cloak_chain.go`, added into `internal/zkapi/` the way `zz_cloak_pay.go` is added to the command package. It must sit in that package because `FundingHandler.config` (`funding.go:92`) and `addressRPC` (`address_funding.go:524`) are unexported. It reuses the daemon's own Tor route and RPC. It pins all reads to the block number that `eth_getBlockByNumber "latest"` returns. Selectors are derived with `crypto.Keccak256`, as `address_withdrawal.go:100` does.

### The one queue

`payTurns` in the guest is strict first-in-first-out (`zz_cloak_pay.go`), so the order is made on the Mac:

- One `R` frame is out at a time. The next leaves only when the last got its `A` or was cancelled.
- Two ranks: `owner` (Chat's Send) and `door` (other apps and the agent). Every waiting `owner` request goes before any waiting `door` request, in arrival order within a rank. Sean's ruling names Chat and a running task; putting other apps with the task is my reading.
- A request already being sent is never cancelled to make room, since a cut after its key is issued may be charged.
- Each press is its own entry; two presses send two requests.
- A cancelled request leaves the queue. If it was being sent, the socket closes, and `cloak-pay` cancels it with nothing spent if its key was not yet asked for (`serve` in `zz_cloak_pay.go`).
- A press on Withdraw does not stop new turns on the Mac, since a press is never held back by page state. The daemon answers 409 `withdrawal_pending` to requests while one is under way (`daemon:cmd/zkapi-clientd/main.go:170-195`), and the Mac shows its own words for that.

`C` and `V` frames never wait in this queue.

### The Mac's own time limit and "still settling"

Step 3 left these for step 6 (`plan.md:967-970`).

- **Still settling.** The Mac cannot tell a held request from one being proved, because only one `A` frame comes back. `H` fixes that: `WaitSettled` takes a callback, `held`, which hears true once, when the hold first finds automatic settlement holding the wallet or the wallet reporting a settlement unfinished, and false once, when the hold ends with nothing pending, just before the key is asked for; `cloak-pay` writes each as an `H` frame. A hold that ends in an error or a hang-up sends no `{"held": false}`, and an `H` that cannot be written ends the request with nothing asked. The request shows `held` between the two, and the sheet shows `settling`.
- **Hold limit: 180 s from `{"held": true}`.** The Mac then hangs up. Nothing was sent or spent, and the stop says so. For scale, the trial saw 35 s after a restart and 77.7 s for the second of two requests.
- **Answer limit: 600 s from the `R` frame, and again from `{"held": false}`.** The stop then says the request may have been charged, as NEAR's does. The daemon's own cap is 30 minutes (`daemon:internal/server/server.go:227`).
- **Calls:** 60 s for reads, 660 s for an approve.

All four are constants in one place, to be set again from step 7's measurements. The Mac never shows the daemon's own message text, which names `zkapi-clientd config` (`plan.md:917-919`); it maps codes to its own words.

## 2. Who signs what

| Action | Who signs | How it starts |
|---|---|---|
| Making the Ethereum key | Nobody; no value moves | First `GET /admin/funding/address` (`address_funding_store.go:66-84`) |
| Funding the address | The owner, in their own wallet | The owner sends ETH on Ethereum mainnet (chain 1) to the address shown |
| Deposit into the vault | The guest's key, on an approved quote only | The owner's press on the review's Deposit |
| Each paid request | The note, by proof in the guest | The owner's Send, or a request carrying a pass the owner issued |
| Settlement | Contract and operator | `cloak-pay`'s own settlement loop; registers a result |
| Withdrawal (`mutualClose`) | The guest's key, with the operator's clearance | The owner's press on the review's Withdraw |
| `claimExpired` | Anyone; contract-defined | Not Cloak's |

- **Where the key lives.** In the guest, in `funding/mainnet/address-funding.json` as hex, mode 0600 (`address_funding_store.go:53-65`), on the encrypted disk. The Mac holds the disk's key and no payment secret.
- **Funding.** The sheet shows the `address` from `AddressFundingStatus`, the network (Ethereum) and the asset (ETH). The owner sends the deposit plus fees. Gas for the later withdrawal also comes from this address, so a fully drained address cannot withdraw until more ETH arrives.
- **Only the owner's press.** A quote cannot sign. The Mac sends `/approve` from exactly one place: the confirm action of a review showing that quote's numbers. An expired quote is re-quoted and shown again, never approved unseen. Opening the sheet, refreshing and polling send only reads and the follow calls above.
- **Where a withdrawal goes.** The daemon requires an explicit destination, fixes it once saved (`address_withdrawal.go:264-266`), and always withdraws the whole balance. Which destination is question 2.
- **The limit of this.** The press is enforced by the app. A taken-over Mac app can approve, and what bounds that is the size of the deposit (`docs/release.md:85-95`).

The agent has no route: `cloak-pay` accepts only the host's vsock address (`zz_cloak_pay.go:195`).

## 3. The Wallet sheet

It keeps today's frame (540 wide, grouped form, the Refresh symbol and Done) and the existing `NearPayment` and `LlamaPayment` for those chats. For Anon and Agent chats:

| State | Contents |
|---|---|
| `unread` | While Cloak is not running, one row: its state in words ("Cloak is paused.") and **Start** beside it; Download Model… in Start's place while the model is missing; a spinner while Cloak starts or stops. No Refresh until Cloak runs. The sheet reads the wallet as soon as it does. |
| `none` | **Address** with Copy and the QR button (reuse `QRCode`). **Network**: Ethereum. **Asset**: ETH. **On hand**: the address's ETH. **Amount**: a dollar field. Under it: "Fees are about $3.50 to deposit and withdraw." Over $50, in orange: "Over $50. Deposit only what you'll spend in 30 days." **Deposit**. While the address holds no ETH, above the amount: "A deposit is paid in ETH from the address above. Send ETH there first; Deposit shows how much." |
| Review (after Deposit, Withdraw or Send Out…) | The row pressed turns into the quote, in its own section, never elsewhere in the sheet: ETH amount, "fee up to" amount, the total, how long the quote holds. Cancel and **Deposit**. While it holds, the sheet reads the chain every 10 seconds, so ETH arriving at the address turns the button on by itself. |
| `depositing` | A down-arrow symbol, "Depositing", "About 3 minutes" (the trial's time). Tooltip per stage. |
| `ready` | Balance large, in ETH, with dollars beneath. A check symbol, tooltip "Ready". **Expires** with the local day and time, and "in 29 days". **Withdraw**. **Deposit** visible, disabled: "One deposit at a time". **Model** picker. |
| A request in turn | As `ready`, with an up-arrow symbol; tooltip "1 sending, 2 waiting". |
| `settling` | As `ready`, with a clock symbol; tooltip "Settling the last request." |
| `near` | An orange banner: "Expires 19 Dec. Withdraw before then." **Withdraw** becomes the prominent button. |
| `due` | A red banner: "Can be taken now." **Withdraw** prominent. |
| `withdrawing` | An up-arrow symbol, "Withdrawing", "About 7 minutes", the destination, and the transaction hash with Copy once there is one. |
| After withdrawal | **On hand** with the leftover ETH and **Send Out…**, which takes an address (the daemon's "return"). |
| `taken` | "This deposit was taken on 19 Dec." No money button. |
| `failed` | A triangle, one or two words by fault, the detail on demand, and Try Again where the daemon allows a resume. Under it, while the address is read: **Address**, **On hand** and **Send Out…**, so ETH there can still be seen and sent out. |

- The info symbol beside **Expires** carries the long words: "After this day anyone can send this deposit to the service's operator, spent or not."
- The vault rounds expiry up to a UTC day boundary (`ZkApiVault.sol:116-119`), so the sheet shows local date and time, not a bare day that could be off by one.
- Outside the sheet, the Wallet toolbar button takes a warning badge in `near`, and Chat shows its existing `Notice` in the last three days.
- The model picker shows each model's cap ("up to $1.00 a request"), because the list has no token prices. A read of the list that stops says so in the row, with Try Again.
- A read of the wallet that stops says why at the top of the sheet, with Try Again, until a read works; while nothing has been read, the sheet shows a spinner only until a read stops. Withdraw pressed before the deposit was read stays on and stops as "Not read", with Try Again for the read.

**Disabled buttons, from the chain read at the latest block only:**

| Button | Condition at the latest block | Words beside it |
|---|---|---|
| Deposit, Withdraw | `paused()` is true | "Paused by operator" |
| Review's Deposit | The address's balance is below the quote's `required_total_wei` | "Address needs 0.0031 ETH more" |
| Deposit | The note is `Active` | "One deposit at a time" |
| Withdraw | The note is not `Active` | "Nothing to withdraw" |
| Withdraw | The address cannot pay the fee | "Needs ETH for the fee" |

A read that fails or is stale enables the button. Settling is not chain state, so Withdraw stays enabled then: the press holds the queue and waits.

The same rule applied to Send and Run changes today's behaviour. `Block` (`app/Sources/CloakChat/Agent.swift:145-165`) holds them back for no wallet and no funds "as the network last showed". Under the rule only "not running" and "the note is not Active on chain" remain. With no deposit the press goes through and is answered 402 `funding_required`.

## 4. The per-request key

**Facts**

- The daemon's own default is 60 seconds, maximum 300: `const DefaultKeyReuseWindowSeconds = 60` at `daemon:internal/config/config.go:20-23`. Its comment says compatible requests share a credential "including requests from different chats and local clients".
- Reuse is matched by budget tier, not by conversation (`daemon:internal/zkapi/client.go:357-361`). Two conversations on two Tor identities would carry one provider key.
- `cloak-pay` sets 0 (`zz_cloak_pay.go:88`), by Sean's ruling of 18 November (`plan.md:2526-2528`).
- The design table commits to "a new key for every request", checked by "Two requests carry two keys; none reaches the Mac" (`release.md:73`). The gate reads "Two conversations share neither a Tor identity nor a payment credential" (`release.md:197`).
- Trial timings (`plan.md`, 17 November):
  - New key each time: 23 to 25 s alone; 23.7 s and 77.7 s for two sent together.
  - 60 s window: 22.9 s and 26.1 s together, and 3.9 s for a third inside the window.
- A note carries one unsettled key at a time, whatever the setting.

**What each choice changes**

| Choice | Code | Elsewhere |
|---|---|---|
| a. New key every request (today) | Nothing | An agent task of 20 model calls spends roughly 10 to 15 minutes on payment alone |
| b. Shared 60 s window | Line 88 removed; `WaitSettled` rewritten to leave a reusable key alone; the two-keys check in `zz_cloak_pay_test.go` replaced | The `release.md:73` row and the conversation-separation gate cannot stand as written; the screen must say what the provider can link |
| c. Window inside one conversation only | A new cache keyed by conversation in `client.patch`, departing from upstream, plus early settlement when another conversation asks | The gate stands; another conversation still waits for the first one's settlement |

## 5. Step 9's deletion list

**Guest**

- `guest/sender/`, whole: `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `src/`, `tests/`, `target/`.
- `guest/build.sh`: "then the sender" in line 10, and lines 53-60.
- `guest/image/build-initramfs.sh`: line 3's words, `cloak-sender` at 38, 70 and 119, the `sender` user at 89 and the group at 101.
- `guest/image/boot`: the comment at 47-53, `sender-ready` at 55, lines 65-68. The line "cloak-guest: sender ready" becomes the payer's.
- Comments in `guest/pay/zz_cloak_pay.go` that name the sender: 13, 68, 75, 193-198.
- `reference/sources.json:84-89` (the `mpp` entry) and `reference/src/mpp/`.
- The Docker volume `cloak-sender-build`, on the build Mac, by hand.

**Host**

- `host/Sources/CloakHost/Sender.swift`, whole.
- `host/Sources/cloak-host/main.swift`: the comment at 19-24 and the `--serve` loop at 116-132.
- Comments at `host/Sources/CloakHost/Guest.swift:10` and `:62`.

**App**

- `app/Sources/CloakChat/Remote.swift`, whole: `WalletKeychain`, `WalletPresence`, `DepositStore`, `Exchange`, `RemoteStop`, `Amount`, `Look`, `Remote`, `Data.init?(hex:)`.
  - `Remote.content(of:)` (289-309) and `Remote.messages(for:in:)` (358-364) move to a file that stays. NEAR uses them at `app/Sources/CloakChat/Near.swift:183` and `:200`.
- `app/Sources/RegentsCloak/Wallet.swift`: the class and `defaultModel`.
- `app/Sources/RegentsCloak/WalletView.swift`: `DevelopmentBar` (392-403), `Account`, `Holding`, the priced `Models`, `RemoteStop.title` and `.words` (430-454), `Amount.text` (456-459), `Double.price`.
- `app/Sources/RegentsCloak/Chat.swift`: the comment at 14-16, `SendStop.stop` at 71, the block words at 262-291, lines 322-323, the send path at 485-515, the `wallet: URL` parameter.
- `Block.noWallet` and `.noFunds` at `app/Sources/CloakChat/Agent.swift:145-165`.
- `app/Sources/RegentsCloak/ChatView.swift`: `DevelopmentBar()` at 158, comments at 14 and 326, the third light at 729, the `Switches` comment and the zkAPI pill at 1008-1022, the "paid by the wallet on this Mac" strings at 1269 and 1273.
- `DevelopmentBar()` at `app/Sources/RegentsCloak/Welcome.swift:25` (comment at 4-8) and `app/Sources/RegentsCloak/AgentsView.swift:28`.
- `app/Sources/RegentsCloak/RegentsCloakApp.swift:52` and `:76-81`.
- `Layout.wallet` at `app/Sources/CloakSupervisor/Manifest.swift:141-143`.
- `app/Sources/CloakSupervisor/Supervisor.swift`: the comment at 15-23, `exchange(request:keep:)` at 378-390, the detail strings at 427 and 443.
- `app/Sources/CloakSupervisor/Verification.swift`: 9-10, 53, 80, 87.
- `app/Sources/CloakDoor/Door.swift`: comments at 72 and 105-116, `Parts.exchange`, `.wallet` and `.key` (129-148), `walletFolder` (175, 196-198), `models()` (518-524), the wallet check and `Remote.complete` (552-572).
- `init(_ stop: RemoteStop)` at `app/Sources/CloakDoor/Failure.swift:49-58`.

**On-screen words that go**

- "Development" and "The provider can link your chats, because one wallet pays for all of them." (twice).
- "USDC.e on Tempo", "The provider no longer names USDC.e on Tempo. Don't add funds.", "Add USDC.e on Tempo to the wallet, then try again."
- "Create", "Cloak makes one wallet on this Mac. You add funds to it, and it pays for each chat you send.", "Cloak couldn't read the wallet."
- "Create a wallet to send.", "Add funds to send.", "Create a wallet to run.", "Add funds to run."
- "Close", "Refunds what's unspent.", and both Withdraw helps about the 15 minutes.
- "zkAPI payment isn't in this build yet."
- The door's "Cloak has no wallet yet. Create one in Chat, under Wallet." and "Add USDC.e on Tempo in Chat, under Wallet."

**Checks**

- `app/Tests/CloakTests/SendTests.swift` and `WalletPresenceTests.swift`, whole.
- The sender's Rust checks, with its folder.
- "sender ready" in `tests/guest_boot.py:176-215`.
- Port 8020 at `tests/test_escape_path.py:122-123`, replaced by 8021.

**Documents**

- `README.md`: 25-26, 55, 267, 426, 449, 455-463, 474-494, 507-512, 603, 647-660.
- `docs/plan.md`: the live status at 1758-1761. Decision 10 (2835-2857) gets an "ended" entry. The words "from the one wallet" in decisions 11 and 12. The passage at 1897-2024 stays as history.
- `docs/state-machines.md`: 374, 893, 937-950, 983. The "Before" entries at 988-1021 are history.
- `docs/release.md`: the build-order lines 97-103, 264-266 and 275.

**Boundless** appears only in documents, at `README.md:462`, `plan.md:2015` and `:2839`, and `release.md:478` (which stays). No code names it; the provider's address is inside `guest/sender`.

**Saved data on a tester's Mac** (from code; I did not look at it)

- A login-keychain item: service `sh.regents.cloak.wallet`, account the Tempo address, label "Regents Cloak wallet", 32 raw bytes, this device only.
- The file `wallet/deposit` in the app's support folder, sealed under the conversations' key.
- No settings key belongs to the wallet (`app/Sources/RegentsCloak/AppSettings.swift:24-34`), and the chosen model is not saved.
- No conversation field refers to it. `app/Sources/CloakChat/Conversation.swift` has only `id`, `created`, `turns`, `near`, `llama`.

After cutover nothing reads either item, and under the no-conversion rule nothing removes them.

## 6. Build order, file by file

Checks come after each part works, and only for money, break-outs and proof before sending.

**Step 6, guest half (built 21 November 2026)**

1. `guest/pay/client.patch`: `WaitSettled` takes `held`, the hold's start and end.
2. `guest/pay/zz_cloak_chain.go` (new): the one-block chain read.
3. `guest/pay/zz_cloak_pay.go`: `C`, `V` and `H`; the allowlist. The `FundingHandler` came with step 5.
4. `guest/build.sh` and `guest/pay/check.sh`: the new file in each overlay.
5. Checks, in `guest/pay/zz_cloak_pay_test.go` (money), against stand-ins:
   - A call outside the allowlist reaches nothing: another method, a query, a path one character off, the chat route.
   - No answer body contains the management token, the API key, the bridge token or the private key, and no call sends a transaction.
   - A `V` holds exactly the contract's keys; a failed chain read answers 502 whole; every chain read is at the one block.
   - `C` and `V` are answered while a request is held.
   - `H` is sent once each way, and not for a request not held; a hang-up while held spends nothing.
6. Real guest, in `tests/test_pay_frames.py`: `V` without the chain finds no note; with it, it fails whole after trying the RPC through Tor; `GET /admin/funding/quote` answers; outside the allowlist, 404. `GET /admin/withdrawal` answers 502 there, as it reads the chain first.

**Step 6, Mac half (can start now, against a stand-in on a socket pair)**

6. `host/Sources/CloakHost/Pay.swift` (new): port 8021 and the frames.
7. `app/Sources/CloakChat/Pay.swift` (new): the wire types, the stop codes, the limits.
8. `app/Sources/CloakChat/PayQueue.swift` (new): the one queue.
9. `app/Sources/CloakSupervisor/Supervisor.swift`: one `pay` call beside `run` (400-403).
10. `app/Sources/RegentsCloak/Wallet.swift`: replaced by the payer's observable model with the named state.
11. `app/Sources/RegentsCloak/WalletView.swift`: the new sheet.
12. `app/Sources/RegentsCloak/Chat.swift`, `app/Sources/CloakDoor/Door.swift`, `app/Sources/CloakDoor/Failure.swift`, `app/Sources/RegentsCloak/RegentsCloakApp.swift`: send through the queue, Chat as `owner` and the door as `door`.
13. `app/Sources/RegentsCloak/ChatView.swift`: the zkAPI pill on; the lights (question 4).
14. Checks, in a new `app/Tests/CloakTests/PayTests.swift` (money, and proof before sending):
    - Open, refresh and poll send no quote and no approve.
    - Approve is sent only by confirm, and never for an expired quote.
    - Two presses send two frames.
    - One request is out at a time, the owner's ahead of the door's.
    - A request being sent is not cancelled for another.
    - `H` then silence ends at the hold limit, with "nothing sent".
    - An unknown phase makes no call.
    - A request frame carries only identity and body.
    - A rewording that stops sends no frame.
15. Break-outs: in `tests/test_escape_path.py`, which holds the payer's break-out checks since step 5, add `C` and `V` frames from the sandbox, plus reads of the funding file as the agent. Done with the guest half: the funding file was already among the agent's reads.
16. Documents: a "Step 6" note under `plan.md:767`, the payer's stages in `state-machines.md`, README, CHANGELOG.

No agent presses Deposit or sends ETH; that is step 8, and Sean's.

**Step 9**: the deletions of section 5, in the order guest, host, app remnants, checks, documents, with one CHANGELOG entry. Under option a of question 1 the app's deletions already happened in items 10-13.

## 7. Only Sean can decide

1. **When does the app switch?**
   - a. At step 6: the app's Tempo parts are replaced in place, and no release is published until step 8 passes.
   - b. At step 9: both paths live in the app for three steps, chosen by the zkAPI pill.
   - b keeps releases possible but means writing branching code to delete later, against the hard-cutover rule.
   - **Recommend a.**

2. **Where does a withdrawal go?**
   - a. An address typed each time. Nothing is saved, but Withdraw is not one press.
   - b. A payout address set once and kept on the Mac.
   - c. The guest's own funding address, as the trial did, with Send Out… for moving it on later.
   - c needs no typing under expiry pressure and cannot be mistyped; it costs one more small transfer fee.
   - **Recommend c.**

3. **The per-request key.**
   - a. Keep a new key each time.
   - b. Shared 60 s window.
   - c. Window inside one conversation.
   - Section 4 has the costs.
   - **Recommend a**, and look at c again after step 7 measures a real agent task.

4. **What does the third light say after cutover?** The payment gate has not passed, so "unlinked" cannot be claimed.
   - a. Drop the light; the zkAPI pill's help says "each request is paid with a new key".
   - b. Keep it orange: "Not yet checked."
   - c. Green.
   - **Recommend a.**

5. **Money in the Development wallet.**
   - a. Before updating, the owner presses Close in the last Development build; the key stays in the keychain, and the release notes say how to read it out.
   - b. Add a "send everything" button to the path about to be deleted.
   - c. Remove the keychain item at cutover, which loses whatever is there.
   - **Recommend a.**

6. **Is Withdraw one press or two?**
   - a. A press shows the amount, fee and destination; a second press signs.
   - b. One press signs the first quote under a fee ceiling shown beforehand.
   - The daemon itself is built around review-then-approve.
   - **Recommend a.**

7. **How far ahead is "well ahead"?**
   - a. 7 days.
   - b. 10 days.
   - c. 14 days.
   - **Recommend b**, a third of the deposit's life.

One fact for his standing decision at `release.md:275-277`, not a new question: finding 3 above. Cloak can only say "Paused by operator" and show the day.

## Could not determine

- Step 4 and 5 details: the disk's mount point and state folder, where the companion listens, the loopback `publicOrigin` that `NewFundingHandler` needs (`funding.go:57-78`), and when `cloak-pay` starts at boot.
- Whether an approve returns at broadcast or waits for finality. The design polls either way.
- What `fee_reserve_wei` covers, and so whether a deposit quote already keeps gas for the withdrawal.
- Whether the deployed vault matches the source at the pinned commit; the contract facts are from source.
- What `GET /admin/status` returns; the design does not use it.
- `X-OA-Verification-Status` does not reach the Mac (`plan.md:915-917`). Whether the Mac should see it is open.
- The default Anon model: `deepseek/deepseek-v4-flash-0731` may not be in this service's list.
- How fast a request with no deposit is refused.
- A second deposit while one is open, the expiry itself and the pause are untried (`plan.md`, "Still not tried").
- Whether Sean's Development wallet holds funds, and how Keychain Access shows its key.
- Whether `scripts/fetch_sources.py` needs more than the entry removed for `mpp`.
- Not read: `relay.patch`, `socks5.patch`, `Runner.swift`, `Tor.swift`, `docs/shots`, `app/release-notes.md`, `CHANGELOG.md`.
- The gbrain server did not connect; nothing here needed it.

### Critical Files for Implementation

- guest/pay/zz_cloak_pay.go
- reference/src/zkapi-mainnet/zkapi-clientd/internal/zkapi/funding_admin.go
- app/Sources/RegentsCloak/Wallet.swift
- app/Sources/RegentsCloak/WalletView.swift
- app/Sources/CloakDoor/Door.swift
