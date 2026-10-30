# Regents Cloak — Product Specification v0.4

**Regents Labs · Version 0.4 · 30 October 2026**

**Status:** Product decision and engineering specification, replacing v0.3. The research report and selected primary source files have been reviewed. No candidate inference, full-stack Mac benchmark or privacy-parity experiment was run for this revision. Candidate selection is a test priority, not a qualification result.

**Product:** Regents Cloak installs and operates the protected reference agent stack through one Mac application or agent-callable terminal interface. v0.4 selects a smaller, native Mac rewriter as a controlled substitution, while preserving the reference harness, daemon contract and other protection layers.

**Planned home:** [regents.sh/cloak](https://regents.sh/cloak), with a download and agent-readable setup guide. This document does not publish a website or installer. Chainagent remains a separate product.

**Positioning:** The private agent stack, ready to run.

**Non-negotiable constraint:** Installation and everyday operation may become simpler. The specified privacy and security protections must not become weaker. An incomplete or weaker integration does not satisfy the product.

**Distribution:** One signed application download, with no dependencies for the user to install separately. The application may contain a Linux guest, executables, runtimes, model weights and configuration. A literal single executable is not required.

## 1. Chosen product path

Build one signed Mac application with the protected Pi stack in its Linux appliance and a native macOS MLX rewrite worker. Evaluate Qwen3.8-27B 4-bit as the lead candidate and Gemma 4 26B-A4B instruction-tuned 4-bit as the challenger. Ship exactly one qualified model/runtime/configuration per release.

The change is deliberately bounded to the local rewriter implementation and its local connection. The model, quantization, inference runtime, decoding configuration and host–guest channel are all part of that substitution. This is not merely a weight-file swap.

Keep Pi, the daemon’s instruction/API/parser/history behavior, zkAPI payment integration, Tor, cover traffic and the reference sandbox/routing policy. OpenShell, Hermes, a new rewriting pipeline and model training are not prerequisites for v0.4.

### Decision summary

| Decision | v0.4 choice |
| --- | --- |
| Product | Automated installation and operation of the complete protected reference workflow |
| Rewriter placement | Native macOS MLX worker; restricted local channel from the Linux guest |
| Lead experiment | Qwen/Qwen3.8-27B using the pinned mlx-community/Qwen3.8-27B-4bit conversion |
| Challenger | google/gemma-4-26B-A4B-it using one verified and pinned MLX 4-bit conversion |
| Shipping configuration | One model and one inference implementation; no model picker, automatic switching or fallback chain |
| Hardware | Qualify on a specified 48 GB Apple Silicon Mac first, and test the same artifact on a specified 32 GB Mac in the same feasibility round |
| Minimum support | Determined by full-product results, never by weight size alone; 32 GB remains a target, not an established promise |
| Interface | One supervisor behind the menu bar and CLI |
| Release rule | Preserve required protections and useful reference behavior; failed or inconclusive required evidence blocks the substitution |
| Deferred | Stronger timing resistance, pruning, expert streaming, placeholders, fine-tuning and additional harnesses |

### Why this path

The report identifies the local rewriter’s memory and latency as a practical obstacle to a consumer Mac package. Its proposed smaller models are plausible experiments. A constrained editor does not automatically need the reference model’s full general capability, but equivalence on this task must be demonstrated. [S23]

Primary sources confirm that Qwen3.8-27B exists, that the named community 4-bit conversion is registered in an MLX implementation, and that Google provides a Gemma 4 26B-A4B instruction-tuned checkpoint. They do not establish the report’s exact weight sizes, licenses, benchmark numbers or Cloak-specific privacy performance. [S16] [S17] [S19]

The reference model’s author describes Flash-Next as a 125B main model plus 51B n-gram embeddings, with 6B parameters activated per token. Small active compute does not imply a small weight footprint. Its architectural differences also mean that Qwen3.8-27B must not be described as a distilled or compressed Flash-Next. [S18]

Prioritize the Qwen candidate for the first integration. Benchmark Gemma in the same controlled round because practical rewriting latency may change the preferred model. If both pass the protection and fidelity gates, choose by measured full-request latency, memory and reliability. General instruction-following scores and model-family resemblance do not decide the shipping result.

### What the report does not settle

- Its published memory and throughput numbers describe other configurations, not the whole Cloak application.
- The captured reference’s thinking/decoding settings must remain unchanged in the primary comparison.
- A positive privacy-degradation margin is not authorized by the user’s no-weakening requirement.
- Synthetic cases alone cannot establish privacy against real-author attribution and repeated-use linkage.
- Failed rewrites, long inputs and cold starts must remain in evaluation denominators.
- Exact weight licenses, conversion provenance, bytes and hashes still need verification before distribution.

The product can progress on packaging and a synthetic-data test harness while these questions are resolved. A working demo is not automatically a qualified release.

## 2. What “equal privacy and security” requires

Equality is assessed against a recorded configuration, task scope and threat model. The release must preserve its mechanisms and demonstrate no identified regression in the tested scope. This is not a mathematical proof against every attack, and the original post is not a security certification.

The trusted device, operating system, guest kernel, approved software and model execution environment are explicit assumptions. The Mac port changes some trusted components; the comparison must include those changes.

### Reference requirements

**REF01 — Capture the baseline.** Record the actual daemon and Pi commits, wrapper arguments, filesystem and network policies, Tor configuration, cover schedule, local model and inference settings, history handling, payment deployment, supported tools and representative tasks. Preserve executable/model hashes and build inputs. A stack assembled from unrelated latest releases is not the reference.

**REF02 — Reproduce before substituting.** Run the captured stack and record its observable behavior before accepting a different harness, sandbox, local model, rewriting pipeline or transport. The inspected development snapshot is research material, not automatically the exact build Vitalik ran.

**REF03 — Preserve the whole workflow.** Compare useful matched tasks, including tools, follow-ups and background activity. Disabling a required capability does not by itself establish equivalent behavior. Unsupported platforms and substitutions remain unavailable.

**REF04 — No silent weakening.** If a required model, daemon, sandbox, route, cover behavior or payment prerequisite fails, stop affected work. Do not fall back to direct cloud calls, an ordinary billed API key, a weaker model, reduced cover or an uncontained agent.

**REF05 — Review packaging changes.** Include installers, new local APIs, guest networking, logs, host–guest channels, updates, storage and shutdown behavior in the review. Identical component names do not prove identical operation.

**REF06 — Keep the limit honest.** Preserve the implemented Tor and cover protections. Do not claim resistance to the active provider/guard timing attack that the post identifies as unresolved. Future mixnet work is not required for the first release. [S01] [S15]

### Mechanisms that must survive packaging

| Layer | Required preservation | Unacceptable shortcut |
| --- | --- | --- |
| Local rewriting | Reference implementation, covered fields, model/settings and request construction, or an evaluated equivalent | Cloud rewriting, skipping fields, untested smaller weights or accidental double rewriting |
| Payment privacy | Compatible zkAPI client, proofs, deployment, credential behavior and recovery | Ordinary account-linked billing represented as equivalent |
| Conversation separation | The reference session unit, history, provider-credential and Tor-isolation lifecycle | Sharing state across unrelated conversations to reduce latency |
| Tor routing | Complete intended agent/tool traffic, DNS behavior and transport failure handling | A proxy setting that leaves other processes or protocols able to connect directly |
| Cover traffic | Qualified schedule, destinations, startup/shutdown behavior and resource envelope | Quietly disabling or reducing it for battery, cost or responsiveness |
| Containment | Actual sandbox policy, allowed files/ports and full harness process tree | Protecting only model calls or one tool subprocess |
| Authority | Reference permission boundaries plus narrow authority for new wrapper operations | Giving the agent wallet-management, update or unrestricted host authority |
| History and content | Preserve reference construction and separation; prevent wrapper-added private display data entering requests | Sending the entire desktop display transcript because it is convenient |

Local rewriting, payment unlinkability and network routing protect different information. A remote model still sees submitted prompt contents. Preserving these layers does not mean identifying clues are impossible. [S10]

## 3. Initial scope, hardware and compatibility

The first protected execution engine remains the pinned Pi workflow. A person can install Regents Cloak directly or ask an authorized local personal agent to install and start the same product.

The release includes a signed app, Linux appliance, qualified native rewrite worker and weights, menu-bar controller, local session interface, CLI, payment/recovery flows, verified startup, updates and removal. No external package manager or separately installed language runtime is required.

### Hardware policy

**HW01.** Begin qualification on one specified 48 GB Apple Silicon Mac. Test a specified 32 GB target during the first feasibility round, not after committing to a model. Record chip, OS, power mode, thermals, ordinary application load and configuration.

**HW02.** Treat approximately 20–30 GB of rewriter memory as a research envelope from the brief/report, not a fixed allocation entitlement. Measure model, cache, transient buffers, runtime, appliance and host load together. Query the actual supported working-set limit. Do not use unsupported OS settings, artificial memory limits or unchecked swap assumptions to claim a device is supported. [S21] [S23]

**HW03.** The same shipped weights/runtime/settings must serve every supported Mac. No automatic smaller model for 32 GB machines. If only 48 GB passes, a transparently limited 48 GB pilot may proceed only after every other protection gate passes; the 32 GB objective remains unmet. Do not claim that 48 GB capacity alone guarantees speed or parity.

**HW04.** Preserve the daemon’s accepted input/deadline behavior. Do not truncate, omit literals, lower the cap or make the task less useful merely to make a device pass. Compare success and latency on reference-supported workloads; also verify safe failure at the boundary.

### Personal-agent roles

1. **Installer/controller:** An authorized local agent installs, starts, inspects or pauses the product.
2. **Protected execution engine:** Another harness can replace Pi only after a separate full-workflow qualification.

A hosted assistant cannot become reference-equivalent by calling the CLI or receiving a local model endpoint. Text already entered into its hosted conversation remains disclosed there. Sensitive task input enters the local protected session; results stay local by default.

Hermes, Muse, Dots, Grokbot and other agents remain possible future integrations according to actual capabilities. A provider name, custom endpoint or partial tool connection cannot satisfy the complete product.

There is one protected product mode at launch. Offline-only work, model-only protection and hosted handoffs cannot substitute for delivering the reference cloud-assisted workflow.

## 4. Architecture: native rewriting, protected Linux agent

The first implementation keeps the Linux reference components in the appliance and runs local model inference on macOS. MLX documents an Apple-silicon/macOS GPU path, while its documented Linux backends are CPU and NVIDIA CUDA. Do not assume that an ordinary Linux guest can use the Mac’s Metal inference path. [S20]

| Component | Location | Permitted authority |
| --- | --- | --- |
| Menu bar / CLI / supervisor | macOS | Approved installation, lifecycle, status and owner flows |
| Pi and its restricted tools | Linux appliance, reference sandbox | Qualified reference task files, tools and routes |
| Privacy daemon and payment services | Trusted appliance services, separated from Pi authority | Existing request construction, rewriting coordination, payment and history rules |
| Guest rewrite adapter | Restricted guest-local service | Existing local chat request/response contract over one authenticated host–guest channel |
| MLX rewrite worker | Native macOS process | Read pinned weights; process bounded text; return the required reply |
| Tor and cover services | Reference network placement | Qualified reference routing, isolation and cover behavior |

### The changed local connection

The daemon retains its existing local chat API. A restricted guest-loopback adapter carries only that request/response contract over an authenticated host–guest channel to the native worker. A guest localhost address does not directly reach a host localhost service.

The adapter must not change prompt bytes, add context, bypass validation, repair invalid semantics, forward arbitrary HTTP, or provide host filesystem/command access. It preserves cancellation, response limits, finish status and the existing deadline. The daemon’s validator remains authoritative.

**MAC01.** Treat the worker and channel as a security-relevant substitution. Verify both host and guest observations. The worker has no tools, wallet authority, arbitrary file access, remote model configuration or external-network authority. Enforce this outside the model; do not rely on a prompt or proxy environment variable.

**MAC02.** Bundle one pinned MLX-based inference implementation and its dependencies. Use an existing compatible model loader rather than writing a new inference engine. The developer may use a bundled language runtime internally; the user installs none. Qualify the exact loader, chat template, tokenizer, kernels and model combination.

**MAC03.** Restrict host–guest channels to the required operation. No automatic home-directory sharing, clipboard synchronization, browser-profile mounts or arbitrary host execution. Session input and allowed files follow the reference permissions.

**MAC04.** Preserve bubblewrap/torsocks and the reference network restrictions for the complete agent process tree. A VM or local rewriter endpoint does not itself establish Tor routing. Disallowed TCP, DNS, IPv4/IPv6, UDP/QUIC and subprocess paths must fail.

**MAC05.** Authenticate the guest adapter, host worker and management endpoints. A local address is not an authorization mechanism. Do not expose an internet listener or a generic model API for compatibility.

**MAC06.** Sign and notarize the app and applicable helpers, use required virtualization entitlements, and preserve macOS protections. The worker’s OS confinement and ability to execute the chosen MLX kernels need qualification together. [S14]

**MAC07.** Load weights from verified local files. No runtime model-hub fetch, analytics or remote tokenizer/config resolution. Keep request bodies out of logs and crash reports. Model-cache, output-buffer and private-memory handling must be tested across cancellation and restart.

**MAC08.** Initially allow one rewrite operation at a time, following the reference serialized inference path. Keep loading/warming behavior visible and bounded. Do not introduce cross-session content caching or speculative/MTP decoding merely to improve benchmark numbers.

### What stays unchanged

The guest remains the home of the qualified Pi workflow, daemon semantics, payment authority, Tor isolation, cover and sandbox policy. Exact placement changes from the captured reference are recorded and tested rather than described as identical software by assertion.

OpenShell and Hermes remain optional later substitutions. v0.4 does not combine a new harness, sandbox and rewriter migration in one experiment.

## 5. One installation engine, two entry points

### Mac application journey

1. Download and open the signed app.
2. Complete applicable macOS approval.
3. The app verifies its packaged assets, initializes state and checks hardware.
4. It starts the appliance and verifies the required protection configuration.
5. Before real funding, it explains recovery and opens the funding review.
6. The user starts the protected Pi session and completes a verification task.

Routine setup is automatic. The person does not configure proxies, choose sandbox flags or install language runtimes.

### Personal-agent journey

An authorized local agent downloads and verifies the same release, installs it in an appropriate location, launches setup and reads structured status. It resumes after any necessary human action. A hosted agent without local execution access provides a handoff to the app; it cannot install software on the Mac merely through a localhost URL.

The terminal interface drives the same controller as the desktop interface. It must not start a second daemon, bypass policy or create an independent wallet writer.

**Proposed interface contract — these are not commands implemented by this document:**

| Operation | Required behavior |
| --- | --- |
| install / setup | Idempotently verify and initialize the signed release; preserve existing user state |
| verify | Run startup checks and a harmless end-to-end verification task |
| start | Launch the complete protected session; open local input or attach the terminal |
| status | Return readiness, active sessions, pending work and the next required action |
| pause / stop | Block new work and execute the qualified shutdown/cover policy |
| resume | Revalidate before accepting new work |
| doctor | Return redacted diagnostics and concrete remedies |
| recovery | Open the owner recovery flow without returning secrets to the caller |
| update | Apply a qualified compatible release through the same update engine |
| uninstall | Stop work and separate conversation deletion from financial recovery |

**INS01.** Emit versioned JSON for automation. Status includes installed release, verification state, session state, reason codes and actionable handoffs. It must not contain prompts, keys, private note material or recovery secrets.

**INS02.** Statuses distinguish needs_os_approval, unsupported_hardware, checking, needs_funding, ready, running, paused and failed. Funding is not needed merely to inspect installation or recovery. Installed is not synonymous with protected and ready.

**INS03.** Keep sensitive task input out of command arguments, shell history and installer transcripts. Use the local session UI or an explicitly authorized protected input channel.

**INS04.** Installer, session and wallet-management authority are separate. Permission to install or start the app does not become permission to withdraw, export recovery secrets, broaden task access or disable enforcement.

**INS05.** Use existing owner authorization where sufficient. OS-required consent, first meaningful permission grants, funding, withdrawals and recovery export remain explicit owner actions. Do not introduce repeated approval prompts for ordinary calls already within the approved scope.

**INS06.** The bootstrap downloads/verifies a pinned signed distribution; it does not run arbitrary model-generated installation commands or assemble floating latest packages. A terminal-only user and a GUI user receive the same versions and configuration.

## 6. Everyday user experience

The main interface is a small menu-bar control, with utility windows for session input, activity, balance, updates and recovery.

| State | User meaning |
| --- | --- |
| Preparing | Components are starting or being verified; new private work is not accepted |
| Ready | The qualified stack is available to start a session |
| Running | A protected session is active |
| Paused | New protected work is blocked |
| Stopping | Task execution is stopping; required transport shutdown or reconciliation remains |
| Needs attention | A requirement failed, with a concrete explanation and remedy |

The primary action is Start / Pause. “Off” means no new protected work; it must never mean running the same task without protections. The UI states the scope of managed activity rather than suggesting that the whole Mac is protected.

Closing a utility window leaves the supervisor running. Quit stops it through the declared shutdown path. Start at login is optional and preserves a deliberate paused state. Wake, restart and updates do not silently resume spending.

Display the actual stack release and relevant verification status. The ordinary user sees useful state and next steps; technical details are available on demand. Do not require understanding Tor circuits or zero-knowledge proofs.

Show local stages such as Loading private model and Preparing private request without false progress percentages. On a rewrite failure, say that the request stopped before remote model submission when that is known. Do not say no network activity occurred: Tor preparation or cover may already have run. Allow cancellation without sending the original as a substitute.

The ordinary UI has no model picker or quantization controls. Keep the rewrite preview available through the existing daemon behavior; it is an inspection aid, not a semantic proof or a new per-call approval gate.

Activity distinguishes prepared, sent, possibly sent, completed and financially pending operations. A request already delivered cannot be recalled by Pause. “Answer ready; charge pending” is an accurate state.

Usability improvements may automate verified configuration, surface errors clearly and shorten manual setup. They may not remove an enforced permission, reduce cover, merge isolated sessions or change the model invisibly.

## 7. Rewriter contract, content and permissions

### Contract verified in the inspected daemon source

The pinned documentation and 16-case development test file were read directly for this revision. They describe the following candidate baseline behavior; the release still needs the exact reference build and configuration captured under REF01. [S08] [S22]

| Contract element | Required preservation |
| --- | --- |
| Input to the rewriter | Each new user turn’s text, with multiple text parts handled together; normal continuation does not send the entire history to the rewriter |
| Historical state | Saved rewrites replay unchanged; unknown older turns are rewritten individually after cache loss, edits or other invalidation |
| Instruction | Exact captured instruction bytes; candidate-specific prompt tuning is not permitted in the primary substitution |
| Reply | Structured JSON with exactly the expected number of strings and the required successful stop finish reason |
| Bounds | 128 KiB input/output text per user turn, 1 MiB HTTP response, 90 seconds per call within the enclosing inference deadline |
| Errors | Malformed output, refusal, truncation, tool calls, HTTP errors and cancellation stop before target inference; no original-text fallback |
| Preserved request fields | Assistant/tool/system messages and supported attachments are not automatically anonymized by this text rewriter |
| Payment/order | Target payment/key acquisition follows successful required preparation; retries/history reconstruction keep the upstream rules |
| Preview | Display metadata must not become new target input; early preview is not proof of completed inference |

The original prompt can contain information intentionally preserved by the task. “Rewritten” does not mean all identifiers disappear. The shipping description must distinguish style normalization from redaction and must not claim that every field or attachment is anonymized.

**DATA01.** Preserve the daemon API, instruction, expected JSON shape, validator, history logic, request fields and error behavior. The new backend must not answer the user’s task or silently add a second rewrite stage.

**DATA02.** Evaluate the lead and challenger as exact artifacts/configurations. For the lead candidate, test non-thinking, low-variance decoding as the proposed worker configuration, subject to the unchanged daemon request. Preserve the actual captured reference’s thinking, precision, sampling and runtime in the primary comparison. An altered reference is a separately labeled diagnostic experiment.

**DATA03.** Preserve original versus target-side history handling. Wrapper-added private annotations, restored names and display-only information never enter outgoing requests implicitly. A richer interface must not serialize its entire displayed transcript.

**DATA04.** No literal-placeholder preprocessing, prompt redesign, fine-tuning, pruning or SSD expert streaming in the initial candidate. If grammar-constrained decoding is used by the chosen runtime, it is an explicit pinned part of that candidate and does not replace the daemon validator or establish meaning preservation.

**DATA05.** Selected files and skills remain within reference permissions. Importing an agent’s full profile, memories or logged-in browser is not automatic. New inputs and authority require an understandable owner choice.

**DATA06.** Treat model output and retrieved content as untrusted. They cannot authorize broader access, higher spending, new destinations or host execution. Unsupported tools stop rather than being redirected to an unrestricted host implementation.

**DATA07.** Render results without implicit remote resources or link previews. Export and opening an ordinary external browser are explicit actions. Validate and bound filenames, paths, parsing and decompression.

**DATA08.** Routine work proceeds within the approved session policy. A new scope requires a decision; each normal inference/tool call does not. An updated model or worker cannot inherit stale qualification.

**DATA09.** Count a safe refusal or timeout as a stopped task, not a successful private rewrite. Preserve its status through the GUI, CLI and evaluation records. The candidate must not appear superior by failing difficult inputs and excluding them from reporting.

**DATA10.** The substitution does not expand the upstream rewriter’s field coverage. Audit Pi auxiliary traffic, skills and history construction as part of the full stack. A raw prompt copied into another message role is not made safe merely by enabling user-message rewriting.

## 8. Networking, isolation and lifecycle

**NET01.** Pin and inspect the reference sandbox and routing configuration, including effective privileges, mounts, allowed ports, process ownership and child processes. The sandbox must not be only a label or environment variable.

**NET02.** Cover main inference, auxiliary requests, tools, delegated work, DNS, retries and supported background activity. Distinguish the restricted agent from Tor and other trusted services that necessarily open their own transport connections.

**NET03.** Preserve conversation isolation across Tor credentials/circuits, upstream provider credentials, target-side history and local session authority. Legitimate within-conversation continuity follows the reference. A prompt prefix or caller-supplied chat ID is not authority to access another session.

**NET04.** Preserve cover behavior and its relevant start/stop semantics. Use only destinations that permit the traffic. Publish its bandwidth and cost envelope; any cap must preserve the required policy or stop affected work instead of silently reducing protection. Bounded random traffic does not establish resistance to active correlation. [S09] [S15]

**NET05.** Use the reference protected DNS and TLS behavior. Test direct TCP, UDP, QUIC, IPv4/IPv6, proxy bypass, redirects and local/private-service access. Installing torsocks alone is not accepted as proof that every possible process path is protected.

**NET06.** Pause, lock, sleep, route loss, daemon failure and application shutdown stop new affected operations. Preserve partial output, transmission uncertainty and financial state. Do not quietly restart the work through a different route.

**NET07.** On resume, verify the actual release, policy, session isolation and pending financial state. Suspension is supported only where the chosen driver and stack make it safe; otherwise stop and recreate the necessary runtime from authorized state.

**NET08.** Do not merge or clone active session/wallet state to accelerate startup or add concurrency. Reuse of immutable public assets is distinct from reuse of private writable state.

**NET09.** Account separately for updates, distribution, RPC/indexer access, payment traffic and diagnostics. New maintenance activity may not transmit task content or create a stable identifier in task requests.

## 9. Payments, recovery and storage

The payment implementation remains the qualified upstream implementation. The product wraps its operation and recovery rather than inventing a new payment protocol.

**PAY01.** Before accepting real funding, qualify the complete client, wallet companion, contracts, service endpoints, proving assets, fee behavior and recovery path. The inspected development snapshot reports unresolved deployment prerequisites. That does not negate the Foundation’s earlier report of a live zkAPI deployment; it means the exact bundle must be matched and verified. [S06] [S10]

**PAY02.** Keep one authoritative writer of wallet, note and settlement state. Both interfaces and all sessions use it. Preserve upstream serialization and add atomic reservations for any wrapper-level budgets. Do not copy wallet files to obtain parallel operation.

**PAY03.** Separate available, reserved, pending and settled amounts. Show model/tool costs and cover costs clearly. Enforce task and global limits before authorizing work; uncertain or incurred costs survive cancellation.

**PAY04.** Persist intent and necessary recovery state before transmission. Use upstream-supported reconciliation after an ambiguous response or crash. A local request identifier does not make an upstream paid action idempotent.

**PAY05.** Before first real funding, explain and offer portable encrypted recovery. Review chain, asset, destination, amount, fees and uncertainty before financial authorization. Keep recovery secrets out of personal-agent chats, arguments and logs.

**PAY06.** The owner authorizes deposit, top-up, withdrawal, destination changes and recovery export. Ordinary task credentials cannot perform those actions. Funding by a friend uses public recipient details only.

**PAY07.** Test restoration on a fresh Mac using an owner-held recovery method independent of the original device. Preserve deployment-specific assets and pending state. Old backups and binary rollback cannot resurrect spent balances or overwrite newer financial records.

**STORE01.** Encrypt app-owned sensitive retained state, including original/released histories where present, private guest overlays, temporary retained data, logs containing content and wallet/recovery material. Keep public immutable assets separate.

**STORE02.** Validate crash dumps, swap/temp behavior and key handling under the stated OS assumptions. No automatic cloud backup, analytics or diagnostics upload may introduce a new content recipient.

**STORE03.** Deleting a conversation revokes active authority and stops its work before removing records and workspace keys. Retain independent financial reconciliation. Explain that exports, backups and remote recipients have independent copies; do not claim physical erasure of SSD media.

**STORE04.** Offer session-only retention and bounded redacted diagnostics. Record only information needed for the user’s operation, inspection and recovery. Support exports are previewable and omit private content by default.

## 10. Updates and removal

**UPD01.** Build and sign a manifest containing app, appliance/kernel, Pi, daemon, worker/adapter, model, runtime, Tor/torsocks, sandbox policy, schemas and payment assets. Pin model repository revision, every weight SHA-256, quantization metadata, tokenizer/config/chat-template hashes, exact instruction bytes, decoder/thinking settings, output limits, runtime build and supported OS range. Record conversion provenance and verify the actual weight license and notices before distribution. A source-code license is not a substitute for a weight license.

**UPD02.** Stage compatible updates, stop new work, preserve required shutdown behavior and migrate state transactionally. Never silently fetch a floating dependency at startup.

**UPD03.** Changes to a protected component or its configuration trigger the relevant reference comparison. A smaller model, new daemon flag or changed Tor/cover default is a security-relevant change, not merely a performance tweak.

**UPD04.** Rollback must preserve current financial truth. If an older binary cannot read newer state, keep a compatible recovery path rather than restoring an old wallet journal.

**UPD05.** Explain distribution and maintenance exposure. A download server may learn that the app was downloaded; the product must not turn that observation into a stable identity accompanying private requests.

**UPD06.** Uninstall stops services and identifies balance/pending work. It offers recovery or withdrawal and separates financial state from conversation deletion. Removing the app is not a withdrawal.

## 11. Evaluation and mandatory release evidence

The v0.3 full-stack gates remain mandatory. Model qualification is additional evidence for a controlled substitution, not permission to replace the complete product with a model demo.

### Three experimental artifacts, one shipped result

Compare the captured Flash-Next reference, Qwen3.8-27B 4-bit MLX and Gemma 4 26B-A4B instruction-tuned 4-bit MLX. Use the real daemon request/response contract. Record all outputs, failures, elapsed time and configuration identities.

The reference can run on suitable high-memory reference hardware; it does not have to fit the target consumer Mac. Rented hardware may process approved synthetic fixtures only. Authored privacy-evaluation data needs a separately approved environment consistent with its permissions; do not upload private product-user prompts to obtain reference answers.

The exact Gemma conversion and both candidates’ weight licenses/hashes must be verified. The named MLX Qwen conversion is community-published, not vendor-certified by its name. Do not treat the report’s embedded citation identifiers as a release manifest.

### Three datasets with separate purposes

**EVAL01 — Regression fixtures.** Retain the 16 inspected synthetic cases as a fast development screen. Their substring checks and manual review do not establish general semantic fidelity or privacy. Extend development coverage without pretending that known fixtures are a held-out result. [S22]

**EVAL02 — Fidelity holdout.** Annotate required task meaning and exact protected spans before examining model outputs. Cover quantities, units, inequalities, negation, uncertainty, conditional order, missing context, code, quotations, names/identifiers, URLs/paths, exact-output rules, multilingual text and long inputs. Check relations, not just the presence of the same numbers. Use blinded human adjudication for ambiguous semantic differences.

Record candidate-only failure, reference-only failure, both fail and both pass. The reference is a comparator, not automatically ground truth. Critical literal or semantic errors in the release corpus are blockers; aggregate wins cannot offset them. A known reference defect is documented rather than used to excuse the candidate.

**EVAL03 — Privacy holdout.** Use permitted authored material from multiple writers, topics and sessions. Split originals before creating rewrites; all versions of one original remain in the same partition. Separate attacker training/tuning from evaluation, control topic leakage and include repeated-use evidence.

Evaluate known-author attribution, cross-session same-author linkability and additional identifying content retained relative to the reference. Use multiple adequately developed attacks with comparable budgets; include an operating point at a predeclared low false-positive rate. Account for dependence between messages from one author/session. Synthetic text alone cannot substitute for this gate.

Use development data to freeze both candidate configurations before opening the final holdout. Preregister the two-candidate comparison and selection rule, and account for both candidates in the statistical analysis. The final holdout can qualify those frozen candidates under that rule; it cannot drive prompt tuning, a new configuration or a new candidate. Any change motivated by final failures requires fresh confirmation evidence. Repeat sufficient reference/candidate runs to characterize stochastic or runtime variation.

### No authorization to weaken privacy

**EVAL04.** Predeclare primary harm metrics, paired analysis, sampling units, confidence level, candidate selection rule and handling of multiple comparisons. Use a fixed preregistered sample size/stopping rule or a statistically valid sequential procedure. The interval method must remain valid with sparse or zero observed paired errors; an all-zero naive bootstrap is not evidence of zero possible regression. For the strict statistical parity claim, define harm difference as candidate harm minus reference harm. The upper one-sided confidence bound must be at most zero for required comparisons; no positive non-inferiority margin is authorized.

A positive or unresolved bound is not a pass. “No statistically significant difference” is insufficient. This conservative rule can require measurable improvement before finite data support a pass; it does not prove universal equality. Additional observations follow the declared stopping procedure or a new confirmatory design. Repeatedly checking ordinary intervals or adding data until a favorable bound appears cannot create a pass, and thresholds may not be relaxed after seeing results.

This is a deliberately conservative v0.4 release policy for the requested parity claim, not the only scientifically valid way to compare models. It avoids silently choosing an allowed privacy loss on the user’s behalf; its cost is that a genuinely equivalent candidate may remain unqualified with finite evidence.

Any confirmed critical candidate-specific disclosure or fidelity regression blocks the candidate independently of averages. Preserve the no-weakening requirement even if both candidates remain unqualified.

### Full-request feasibility before expensive evaluation

**EVAL05.** Measure through the actual daemon, local adapter and worker with the Linux appliance and declared ordinary Mac load active. Test cold load, warm operation, cache loss/history reconstruction, long outputs, cancellation, memory pressure, sleep/wake and restart. Include rejected, malformed and timed-out requests in denominators.

The 128 KiB limit is bytes, not a promise that every input finishes in 90 seconds. Compare reference-supported successful workloads and verify safe failure near the upper bounds. A candidate that times out on workloads the reference completes is not equivalent merely because it stops safely. Do not silently truncate text, lower the input limit or exclude long tasks to pass.

The report cites 42.3 prompt tokens/second for one external configuration. At that rate, 4,000 uncached input tokens alone imply about 94.6 seconds before generation. This arithmetic is not a Cloak prediction; it shows why the cited benchmark cannot establish the daemon deadline. Literal-heavy output may also approach input length. [S23]

**EVAL06.** Set practical interaction targets before measurements. Proposed initial targets on each supported machine: warm full rewrite p50 at most 5 seconds and p95 at most 15 seconds for a fixed ordinary-message test set capped at 512 input tokens with declared expected output lengths. These are engineering targets, not observed performance or input-cap changes. Report cold-load and larger-length buckets separately, plus total task overhead and all deadline failures.

If those targets prove unsuitable, record the product decision explicitly; do not conceal long delays in generation-speed averages or silently reduce privacy work. The unchanged 90-second daemon limit remains a safety ceiling, not a good everyday UX target.

**EVAL07.** Measure total memory/pressure, swap growth, installed/download size, CPU/GPU use, battery and end-to-end latency. Do not infer 32 GB viability from isolated model allocations or raise system limits to hide pressure. The inspected MLX implementation constrains wired limits using the recommended working-set value. [S21]

### Full-product acceptance suite

| ID | Test | Required evidence |
| --- | --- | --- |
| A01 | Reference integrity | Actual model/configuration, daemon, Pi, policies, deployment and tasks are pinned and reproduced |
| A02 | Clean Mac installation | Complete stack reaches working state without manual dependency installation |
| A03 | GUI/CLI equivalence | Same manifest, supervisor, sessions and single payment writer |
| A04 | Fidelity | Protected literals and blinded meaning review pass EVAL02; no unresolved critical errors |
| A05 | Whole-agent containment | Disallowed files, host operations, privileges and cross-session state remain inaccessible |
| A06 | Complete routing | Main/auxiliary calls, tools, children, DNS and alternative connection paths cannot bypass the qualified route |
| A07 | Conversation isolation | Switching, retries, cache loss and restart preserve reference identity/history behavior |
| A08 | Cover behavior | Observed schedule and lifecycle match policy; resource caps cannot silently reduce it |
| A09 | Failure and pause | Worker/model/route failures, Pause, Quit and sleep/wake stop affected work without fallback |
| A10 | Local authority | Forged sessions, unrelated pages and ordinary task credentials cannot administer policy, host or wallets |
| A11 | Actual paid workflow | Real deployment funding, usage, fees, settlement and withdrawal are qualified |
| A12 | Financial interruption | Lost replies, duplicate retries and crashes preserve correct reconciliation and authorization |
| A13 | Fresh-device recovery | Owner-held encrypted recovery restores, reconciles and can spend/withdraw on another qualified Mac |
| A14 | Wrapper disclosure | Logs, rendering, display metadata, export and diagnostics add no unauthorized content recipient |
| A15 | Updates/rollback | Configuration changes requalify; financial truth and protected behavior survive |
| A16 | Deletion/removal | Revoke authority before removal; financial recovery remains deliberate |
| A17 | Hardware | Each advertised 32/48 GB configuration passes full-product memory and task tests with identical artifacts |
| A18 | Usability | First-time users install, start, inspect, pause and recover without terminal/configuration work |
| A19 | Claims | Public statements match tested scope and the inherited Tor/content limitations |
| A20 | Unchanged rewrite API | Same instruction/schema/limits/parser/history behavior; invalid outputs never reach target inference |
| A21 | Host–guest worker boundary | Authenticated narrow channel; no external worker egress or generic host proxy |
| A22 | Authorship/linkability | Proper authored holdout and strict preregistered privacy comparisons pass EVAL03–04 |
| A23 | Long/cold tasks | Full completion and parsing meet qualified deadlines; failures and lost capability are counted |
| A24 | Artifact provenance | Exact weights, conversion, licenses, template, runtime and configuration are verified and pinned |
| A25 | Single implementation | No model picker, hardware-based switching, automatic cloud/original fallback or hidden second rewrite |
| A26 | Performance claims | Actual product measurements support advertised hardware and responsiveness; benchmark citations are not substituted |

Publish or retain the reference/release manifests, comparison data, adjudications, relevant network traces, financial recovery results and known gaps. Have at least five first-time users complete the full journey and an interruption exercise. Usability evidence does not replace protection evidence. A failed or inconclusive required gate does not count as a pass.

## 12. Delivery plan and decision rules

| Stage | Concrete output | Exit condition |
| --- | --- | --- |
| 1. Freeze the experiment | Captured reference, inspected 16 cases, unchanged contract, candidate manifests and evaluation protocol | Exact assets/licenses and primary settings are known; unknowns are recorded |
| 2. Build the local path | Minimal guest adapter plus native MLX worker through the real daemon | Synthetic inputs, malformed replies, cancellation and worker loss preserve the contract and fail safely |
| 3. Check feasibility early | Qwen and Gemma runs on specified 48 GB and 32 GB machines with full stack load | Input/deadline/memory risks are measured before a large privacy evaluation |
| 4. Qualify the substitution | Separate fidelity and authored privacy holdouts; one pinned winner or explicit no-pass | Protection, fidelity, statistical and usability gates pass |
| 5. Package the product | Signed full bundle, shared CLI/menu supervisor, setup, recovery, updates | Clean-machine and full real-service tests pass |
| 6. Release at the planned home | Download/guide and evidence for supported configurations | A01–A26 pass; claims and hardware scope match results |

### Model and hardware decisions

- **Qwen passes; Gemma does not:** ship the qualified Qwen artifact.
- **Gemma passes; Qwen does not:** ship the qualified Gemma artifact.
- **Both pass:** prefer better measured full-request responsiveness, memory behavior and operational reliability within the same protection requirements.
- **Only 48 GB passes device qualification:** consider an explicitly 48 GB limited pilot with the same qualified artifact; keep 32 GB support unfulfilled and unavailable.
- **A candidate fails or has inconclusive required evidence:** that candidate cannot ship. If neither candidate qualifies, neither substitution ships; preserve the reference on suitable hardware or defer the affected Mac release. This says nothing conclusive about all models in the size class.
- **Failures cluster in one mechanism:** diagnose before expanding work. Different quantization, placeholders, decoder changes or fine-tuning create a new candidate and require a new decision and evaluation.

Do not add the 12B, 9B and E4B controls to the first release effort. Use them later only to answer a concrete unresolved question. The first investment is one real daemon path, the evaluation corpus and reusable invariant checks.

Fixtures and test funds support development but cannot satisfy actual payment/recovery release gates. Do not expose an unqualified substitution to private customer prompts under a claim of parity.

### Website and onboarding

Use the planned Regents Cloak page for the supported Mac download, setup guide, exact release manifest, system requirements and limits. The two primary actions remain Download for Mac and Set up with your agent.

No Regents account, SIWA identity, wallet sign-in or account-linked credits are required merely to obtain or use the qualified private route. Distribution and support activity remain separate from protected task traffic. The menu bar and CLI remain the product’s operating interface.

## 13. Future work

### F01 — Stronger timing resistance

**Future TODO; not an initial-release requirement.** Preserve the demonstrated Tor/cover baseline and disclose its active-correlation limitation. A specialized mixnet remains separate research. [S01] [S15]

A future stronger claim requires a defined attacker, both-direction evaluation, streaming/retries, startup/shutdown, realistic competing traffic and resource/cost measurements. A successful transport connection is insufficient.

### Other deferred changes

- OpenShell or another execution-boundary substitution.
- Hermes and additional fully managed harnesses.
- Literal-placeholder preprocessing or a new disclosure/minimization pipeline.
- Expert pruning, SSD expert streaming, fine-tuning or distillation.
- Additional quantizations, smaller controls and alternative model/runtime releases.
- Speculative/MTP decoding or performance changes that alter the qualified execution.
- OS-managed or floating models that cannot meet the required pinning and evaluation contract.
- Additional platforms, authenticated personal-account tasks and hosted result handoffs.
- Qualified local-only workflows with separate capability/disclosure claims.

These are not hidden launch dependencies. They may not be used as automatic fallback paths when the selected model fails.

## 14. Definition of done and v0.4 change record

A non-technical person can install Regents Cloak directly or through an authorized local agent, obtain the complete protected Pi workflow, and use one qualified native local rewriter without choosing models or configuring dependencies.

They can start and pause work from the menu bar, inspect state and charges, recover after interruption/device loss, and update through the same verified distribution. The advertised hardware and performance match full-product evidence.

The smaller local model ships only when its exact implementation meets the reference protection and usefulness requirements. A limited hardware release is labeled accurately. If a required protection or comparison fails, that configuration remains unavailable.

### Changes from v0.3

- Adopted the Regents Cloak name and planned regents.sh/cloak distribution.
- Selected native macOS MLX rewriting as the controlled substitution path.
- Prioritized Qwen3.8-27B 4-bit and Gemma 4 26B-A4B as two experiments, with one shipped implementation.
- Kept Pi, daemon semantics, payment privacy, Tor, cover and sandbox protections as the reference.
- Verified the candidate daemon’s actual per-user-turn rewriting scope, byte limits, 90-second deadline and 16 development cases.
- Added separate fidelity, authorship/linkability and full-product feasibility gates.
- Prohibited changing the reference’s thinking settings or allowing a positive privacy-weakening margin to manufacture parity.
- Made 32 GB support conditional on the same artifact passing real device tests.
- Retained funding/recovery, installation, pause, update, deletion and no-fallback requirements.
- Kept stronger timing resistance as future TODO F01.

**Product statement:** The private agent stack, ready to run. Simpler installation and operation, with no reduction in the reference protections required for release.

## 15. Sources and evidence limits

The research report was read in full on 30 October 2026. Selected primary GitHub files were also retrieved that day; earlier platform references carry forward the 29 October review. General web/model-card retrieval failed during this revision, so the report’s exact artifact sizes, weight licenses and third-party Mac benchmark figures remain attributed to the report, not independently reverified results. No model or device experiment was run.

Sources establish upstream capabilities or reported intent, not completed product tests. The original October post does not contain every reproducible setting. Candidate snapshots are not automatically Vitalik’s exact build or a deployable production bundle.

- **[S01] Vitalik’s October 16 post:** Pi, private daemon, local rewriting, zkAPI, Tor isolation, random cover, bubblewrap/torsocks, latency and future timing work.
- **[S02] Vitalik’s April setup article:** Local tools, sandboxing and separated authority.
- **[S03] Bubblewrap README:** Linux facilities and the importance of the caller’s actual sandbox policy.
- **[S04] Apple Virtualization:** Operating-system APIs for custom Linux guests.
- **[S05] Apple Linux guest guide:** Architecture-specific kernel/guest requirements and packaging.
- **[S06] Pinned zkAPI client snapshot:** Candidate client/deployment constraints.
- **[S07] Pinned zkAPI privacy documentation:** Session, credential and recovery boundaries.
- **[S08] Pinned zkAPI rewriter documentation:** Candidate transformation and history behavior.
- **[S09] Pinned zkAPI cover documentation:** Candidate cover behavior and limits.
- **[S10] Ethereum Foundation zkAPI introduction:** Payment privacy, remote-content visibility and reported live deployment.
- **[S11] OpenShell architecture:** Execution, policy and request mediation capabilities.
- **[S12] OpenShell support matrix:** Platform/runtime requirements for a possible substitution.
- **[S13] Tauri sidecars:** An optional packaging technique, not a mandatory UI framework.
- **[S14] Apple downloaded-application guidance:** Signing/notarization and first-launch behavior.
- **[S15] Tor remaining attacks:** Timing-correlation limitations.

- **[S16] Official Qwen3.8 README, pinned:** Model availability and local runtime paths; weight licensing is delegated to the actual weight distribution.
- **[S17] MLX Swift model registry, pinned:** Registers the named Qwen3.8-27B community 4-bit conversion; not proof of Cloak qualification.
- **[S18] Official Flash-Next README, pinned:** Main/embedding parameter counts, active parameters and architecture context.
- **[S19] Google Gemma checkpoint registry, pinned:** Confirms the Gemma 4 26B-A4B instruction-tuned checkpoint.
- **[S20] MLX installation/build documentation:** Native Apple GPU path and documented Linux backends; read blob f9d02205b8c0a4d61b94090944c1a88384a7bb0d.
- **[S21] MLX Metal allocator, pinned:** Runtime working-set and wired-limit handling.
- **[S22] Pinned daemon instruction evaluation:** The 16 synthetic development cases, mechanical assertions and manual-review limits.
- **[S23] User-supplied local rewriter research report:** Candidate rankings and external benchmark claims; its embedded citation identifiers are not reused as independently retrieved sources.

[S01]: https://x.com/VitalikButerin/status/2111046730959433793
[S02]: https://vitalik.eth.limo/general/2026/04/02/secure_llms.html
[S03]: https://github.com/containers/bubblewrap
[S04]: https://developer.apple.com/documentation/virtualization
[S05]: https://developer.apple.com/documentation/virtualization/creating-and-running-a-linux-virtual-machine
[S06]: https://github.com/ethereum/zkapi/blob/eac5f9065421b729d8415a6f0fc9085389472ba7/zkapi-clientd/README.md
[S07]: https://github.com/ethereum/zkapi/blob/eac5f9065421b729d8415a6f0fc9085389472ba7/zkapi-clientd/docs/PRIVACY.md
[S08]: https://github.com/ethereum/zkapi/blob/eac5f9065421b729d8415a6f0fc9085389472ba7/zkapi-clientd/docs/REWRITER.md
[S09]: https://github.com/ethereum/zkapi/blob/eac5f9065421b729d8415a6f0fc9085389472ba7/zkapi-clientd/docs/COVER_TRAFFIC.md
[S10]: https://blog.ethereum.org/en/2026/10/01/introducing-zkapi
[S11]: https://docs.nvidia.com/openshell/v0.1.6/about/architecture
[S12]: https://docs.nvidia.com/openshell/v0.1.6/about/support-matrix
[S13]: https://v2.tauri.app/develop/sidecar/
[S14]: https://support.apple.com/en-us/102445
[S15]: https://support.torproject.org/about-tor/security/attacks-on-onion-routing/

[S16]: https://github.com/QwenLM/Qwen3.8/blob/2ea10dc725823bf7c3e21ce8557cbe15245132ae/README.md
[S17]: https://github.com/ml-explore/mlx-swift-lm/blob/f5b0677f6b52b81d068871611cfcb82d1e7a0005/Libraries/MLXLLM/LLMModelFactory.swift
[S18]: https://github.com/QwenLM/Qwen3.8-Flash-Next/blob/69885871a64393807d988b27b1b5e380e8f28526/README.md
[S19]: https://github.com/google-deepmind/gemma/blob/9e1f74131ba9d45e5fe6ae7bb3941d9f2abb39c3/gemma/gm/ckpts/_paths.py
[S20]: https://github.com/ml-explore/mlx/blob/main/docs/src/install.rst
[S21]: https://github.com/ml-explore/mlx/blob/1ba7f969ad05d86decfeeb83787cc9b79e440962/mlx/backend/metal/allocator.cpp
[S22]: https://github.com/ethereum/zkapi/blob/eac5f9065421b729d8415a6f0fc9085389472ba7/zkapi-clientd/internal/rewriter/instruction_eval_test.go
[S23]: https://chatgpt.com/library?file_id=libfile_c11f4c48331c8191894892418b994b89&account_id=personal


