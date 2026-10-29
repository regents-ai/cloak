# Reference baseline (REF01)

The reference is the setup Vitalik described on 16 October 2026
([post](https://x.com/VitalikButerin/status/2111046730959433793)): Pi wrapped
in a bubblewrap sandbox and torsocks, talking to the zkAPI daemon, which
rewrites prompts locally, isolates conversations on separate Tor circuits,
adds cover traffic and pays through zkAPI.

Each item has one status:

- **captured**: taken from a published, pinned source.
- **reconstructed**: our best reading of published material; the original is
  unpublished. Sean ruled on 29 October that the reconstruction is the Regents
  reference, so A01 records these items as reconstructed, not copied.
- **unknown**: not published and not yet reconstructed.

Recorded 29 October 2026. Pins live in [sources.json](sources.json) and are
verified by `uv run scripts/fetch_sources.py`.

## Components

| Item | Status | Value | Source |
| --- | --- | --- | --- |
| Privacy daemon | captured | `zkapi-clientd` from `vbuterin/zkapi` branch `feat/client-concession-local` at `0fb263b0`, committed 10:26Z on 16 Oct, 22 minutes before the post; the branch has not moved since | Link in the post; `git ls-remote` |
| Daemon engine actually run | unknown | The branch builds a concession engine and a legacy engine. Concession was `not_deployed` on every network at this commit, so a working wallet then had to be a legacy profile | `docs/LOCAL_PROTOCOL_MIGRATION.md` at `0fb263b` |
| Legacy engine inputs | unknown | Legacy companion `zkapi-walletd` and its proving assets are not in the repository ("recover them from your reviewed legacy installation") | `docs/DEVELOPMENT.md` at `0fb263b` |
| Daemon build | captured | Go, `-trimpath`, version `privacy-0fb263b-dev`; linux/arm64 static binary sha256 `3df72bb8cc0fd7df43e138b2a74e589d5f7ca5a519b51141562c52f478cd4f08` built with Go 1.26.1 | `docs/DEVELOPMENT.md`; our build |
| Later snapshot | captured | `ethereum/zkapi` at `eac5f906` (23 Oct), the commit the spec cites; 45 commits after the post's commit; adds a Sepolia staging deployment with a development proving setup | Spec S06 to S09 |
| Agent harness | reconstructed | Pi, npm `@earendil-works/pi-coding-agent@1.3.0` (source tag `v1.3.0`, `71023aec`), the newest release when the post went out. The post names Pi but not its version | npm registry times |
| Pi provider | captured | `openai-completions` API against the daemon at `http://127.0.0.1:8787/v1`, empty key or `local` | `zkapi-clientd/README.md`, `docs/REWRITER.md` |
| Pi network settings | reconstructed | `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1`, `PI_TELEMETRY=0` so Pi makes no background requests of its own | Pi `docs/environment-variables.md` |
| Sandbox | reconstructed | bubblewrap with every namespace but network unshared, read-only `/usr`, a private home and one workspace: [wrapper/sandbox](wrapper/sandbox) | Post: "wrapped with a bwrap sandbox"; exact arguments unpublished |
| Network wrapper | reconstructed | torsocks inside the sandbox, `AllowOutboundLocalhost 1` so Pi can reach the daemon: [wrapper/torsocks.conf](wrapper/torsocks.conf) | Post: "wrapped again with torsocks" |
| Tor | captured | `SocksPort 127.0.0.1:9050 IsolateSOCKSAuth`; daemon route `tor://127.0.0.1:9050`: [wrapper/torrc](wrapper/torrc) | `docs/CLI_ZKAPI.md` ("Tor") |
| Conversation isolation | captured | Daemon keeps a random SOCKS identity while each request's history extends the previous one; any other history gets a fresh identity and a fresh provider key | `docs/CLI_ZKAPI.md` ("Tor") |
| Key reuse window | captured | Default 60 seconds; with Tor or rewriting on, only prefix-continuing histories share a key | `zkapi-clientd/README.md` |
| Cover traffic | captured | Native worker, Poisson arrivals, default 5 per second, 4 in flight, 20 s and 64 KiB per request, each worker on its own SOCKS identity | `docs/COVER_TRAFFIC.md` |
| Cover destinations | unknown | Operator-chosen HTTPS URLs; Vitalik's are unpublished | `docs/COVER_TRAFFIC.md` |
| Local rewriter | captured | `--rewriter-url http://localhost:8012 --rewriter-model qwen3.8-flash-next`, default instruction of about 253 tokens, preview shown as reasoning | `docs/REWRITER.md`, `docs/REWRITER_EVALUATION.md`; matches the post's first screenshot |
| Rewriter model | captured | `Qwen/Qwen3.8-Flash-Next` (Hugging Face `de4b8e4d`), 180B-parameter mixture of experts | Post; Hugging Face |
| Rewriter weights and server | unknown | Quantization and inference server unpublished. The smallest published quantizations are 66 to 72 GB | Hugging Face file listings |
| Web search | captured | On by default through OpenRouter's web plugin | `zkapi-clientd/README.md` |
| Payment deployment | unknown | Which network and vault the post's wallet used. Mainnet concession is not deployed at either pin | `docs/LOCAL_PROTOCOL_MIGRATION.md`; post: "cheaper ... coming to mainnet soon" |

## Representative task

See [tasks.md](tasks.md).

## Observed behaviour of the reconstruction

Run on the stage 1 Linux host ([host/](host/)) on 29 October 2026: Debian
trixie arm64 in Docker Desktop's Linux VM, tor 0.4.9.15, torsocks 2.5.0,
bubblewrap 0.12.0. The host differs from Vitalik's machine; differences that
matter are noted.

| Check | Result |
| --- | --- |
| Daemon `go vet` and `go test -race ./...` at `0fb263b` (macOS arm64) | All packages pass |
| Pi 1.3.0 starts inside the sandbox | `pi --version` prints 1.3.0 |
| curl inside the sandbox | Reaches check.torproject.org through Tor |
| UDP from Python inside the sandbox | Refused by torsocks |
| A statically linked program inside the sandbox | **Reaches the internet directly**, over both TCP and UDP DNS, not through Tor |
| torsocks when its library cannot load | **Continues without Tor**: the loader prints a warning and the program runs unwrapped |

The two bold rows are limits of a torsocks-only wrapper with a shared network:
torsocks works by preloading a library, so anything that does not load it
(static binaries, programs with their own resolver, a missing library) connects
directly. They are findings about the reference itself, since the
reconstruction is the Regents reference. The spec's A06 needs routing that is enforced, not preloaded, and the Mac
appliance must provide that.

Not yet reproduced: any paid inference, rewriting with the reference model,
cover traffic against real destinations, and the representative task end to
end. Each is blocked by an unknown above.
