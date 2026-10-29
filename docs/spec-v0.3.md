# Private Agent — Reference Stack Product Specification

**Regents Labs · Version 0.3 · 29 October 2026**

**Status:** Proposed product and engineering specification. This revision replaces v0.2. It defines required behavior and release evidence; the application, installer and parity results have not been implemented or demonstrated here.

**Product:** Install and operate the complete private-agent setup described in Vitalik’s October 16 post through one Mac application or an agent-callable terminal interface.

**Non-negotiable constraint:** Installation and everyday operation may become simpler. The specified privacy and security protections must not become weaker. An incomplete or weaker integration does not satisfy the product.

**Distribution:** One signed application download, with no dependencies for the user to install separately. The application may contain a Linux guest, executables, runtimes, model weights and configuration. A literal single executable is not required.

## 1. The product decision

Build an automated distribution and supervisor for the reference stack. Start by reproducing Pi, the privacy daemon, local rewriting, zkAPI, Tor conversation isolation, cover traffic, and the bubblewrap/torsocks wrapper described in the post. Keep the same useful workflow while making installation, startup, status, spending and recovery understandable. [S01]

The Mac interface and terminal interface operate the same supervisor, configuration, sessions and payment state. A user can install the app directly. An authorized personal agent can install and launch exactly that same product.

OpenShell is an optional change to the execution boundary. Hermes is an optional change to the agent harness. Neither is necessary merely to automate installation. Each change must demonstrate that it preserves the relevant reference protections and useful behavior before it replaces a working component.

There is one protected product mode at launch. Model-endpoint-only access, a hosted-agent handoff and an offline-only demonstration cannot substitute for delivering the complete reference workflow.

### What changed from v0.2

- Pi and the reproduced reference configuration come first; Hermes is no longer the initial baseline.
- OpenShell is no longer a mandatory architectural dependency.
- Partial integration tiers are removed from the initial product.
- The new, bespoke disclosure-controller architecture is removed as a prerequisite to packaging the reference.
- Reference reproduction and checks for regressions are mandatory release gates.
- The desktop app and CLI share one implementation.
- Stronger timing resistance remains future TODO F01.

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

## 3. Initial scope and agent compatibility

The initial product ships on a qualified Apple Silicon macOS configuration. The first supported agent is the pinned Pi workflow. The product includes:

- A signed app with its complete appliance and working local rewriting assets.
- A menu-bar controller and a local session window or terminal attachment.
- A terminal interface for installation, launch, status and lifecycle operations.
- The complete private cloud workflow, with funding, spending, withdrawal and recovery.
- Verified startup, failure handling, updates and removal.

A standalone local-only mode can be considered separately; it does not satisfy the cloud-workflow release gate. It must not be introduced merely because the full reference is difficult to package.

An existing personal agent has two possible roles:

1. **Installer/controller:** It helps install, start, inspect or pause the product through authorized local operations.
2. **Protected execution engine:** It replaces Pi inside the complete protected environment only after qualification.

A hosted assistant does not become reference-equivalent by invoking the CLI or receiving a new endpoint URL. Anything already entered into its hosted conversation remains disclosed there. Full task input should enter the protected local session, and results remain local by default.

Hermes, Muse, Dots, Grokbot or another agent may be supported according to its actual runtime and capabilities. A brand or custom-model setting cannot establish equivalence. There is no requirement to certify all of them for the initial release.

## 4. Mac packaging architecture

### Starting implementation

Bubblewrap relies on Linux kernel facilities and the supplied policy. To preserve that boundary on a Mac, package a Linux guest containing the Linux reference components. Apple’s Virtualization framework supports creating and running Linux guests; this makes a prepared appliance a feasible packaging approach. It does not itself prove privacy or route all traffic through Tor. [S03] [S04] [S05]

The proposed initial appliance contains the reference Pi runtime, privacy daemon and payment components, Tor/torsocks, local inference and rewriting assets, bubblewrap policy and required utilities. Trusted services and the restricted agent retain their separate identities and access boundaries inside the guest. One VM must not collapse every component into a single unrestricted process authority.

The app owns VM lifecycle through the operating system’s virtualization facilities. It does not require the user to install Docker, Homebrew, Node, Python or a compiler. Required guest architecture and hardware support are tested and published.

### Placement rules

**MAC01.** Start with the closest workable placement to the reference. If native macOS inference is needed for acceptable acceleration, treat moving the local rewriter across the host–guest boundary as a documented change. Test its local channel, access restrictions, data handling and model behavior before shipping.

**MAC02.** Benchmark the exact model, quantization and inference settings. Do not silently select smaller weights, reduce rewriting quality or use cloud inference to make a machine appear supported. Report the tested RAM, disk, download size, latency and resource limits.

**MAC03.** Expose only necessary host–guest channels. No automatic home-directory sharing, clipboard synchronization, browser profile mounting or unrestricted host command execution. Explicit file transfer must preserve the reference task’s allowed access.

**MAC04.** A guest network adapter is not permission for the sandboxed agent to bypass Tor. Preserve the wrapper and daemon routing, with enforced restrictions on alternative agent paths. Verify host and guest observations, including DNS, IPv6, UDP/QUIC and subprocess attempts.

**MAC05.** Keep control endpoints local and authenticated. Neither the VM’s private address nor a loopback address is a sufficient authorization check. Do not expose wallet or administrative APIs to the internet for agent compatibility.

**MAC06.** Use Developer ID signing/notarization and appropriate virtualization entitlements. Do not bypass Gatekeeper, disable OS protections, or ask users for broad Accessibility/Full Disk Access merely to run protected research. [S14]

### OpenShell decision

OpenShell can provide managed execution, policy and mediated network access. Its documentation does not establish that swapping it in preserves the reference Tor, rewriting, payment or history behavior. [S11]

Evaluate it after the working reference is captured. It may be useful if it reduces maintenance or improves enforcement without a regression. Ship one qualified implementation first; do not build a generic runtime abstraction or multiple execution engines merely to keep both options open.

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

Activity distinguishes prepared, sent, possibly sent, completed and financially pending operations. A request already delivered cannot be recalled by Pause. “Answer ready; charge pending” is an accurate state.

Usability improvements may automate verified configuration, surface errors clearly and shorten manual setup. They may not remove an enforced permission, reduce cover, merge isolated sessions or change the model invisibly.

## 7. Content, tools and permissions

**DATA01.** Preserve the reference daemon’s request construction, rewriting and history behavior. Document which fields are transformed, which are preserved and which are unsupported. Do not describe its rewriter as a universal anonymizer. The inspected rewriter documentation is evidence about a candidate implementation, not proof of all-field privacy. [S08]

**DATA02.** Use the reference local model/settings first. Evaluate any alternative on both identifying disclosure and useful task behavior with held-out examples. Include multi-turn history, code, exact quantities, quotations, rare identifiers, multilingual inputs and auxiliary calls.

**DATA03.** Preserve reference separation between original and target-side histories where implemented. If the wrapper adds private annotations, restored names, labels or display-only information, keep those additions out of outgoing requests. A richer interface must not serialize its entire displayed transcript into the next model call.

**DATA04.** Do not invent a new research agent, rewriter or elaborate release controller as a prerequisite for packaging the stack. Additional content controls are explicit later changes with their own claims and evaluation.

**DATA05.** Selected files and skills must remain within the qualified reference permissions. Importing an agent’s complete profile, memories or logged-in browser is not automatic. New inputs and permissions require an understandable owner choice.

**DATA06.** Model output and retrieved pages are untrusted. They cannot authorize broader access, higher spending, new destinations or host execution through the wrapper. Unsupported tools stop clearly rather than being redirected to an unrestricted host implementation.

**DATA07.** Render results without implicit remote resources or link previews. Export and opening an ordinary external browser are explicit user actions. Filenames, paths, decompression and parsing are validated and bounded.

**DATA08.** Preserve routine work within the approved session policy. New scope requires a decision; each normal model/tool call does not. Record the actual policy used so an update or reconnect cannot inherit stale authorization.

The product does not claim that every supported agent receives identical capabilities on every machine. A qualification decision must state supported tasks and limits rather than presenting removed functionality as an uncomplicated improvement.

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

**UPD01.** Build and sign a manifest containing app, appliance/kernel, Pi, daemon, model, runtime, Tor/torsocks, sandbox policy, schemas and payment assets. Verify immutable artifacts at installation. Include redistribution licenses.

**UPD02.** Stage compatible updates, stop new work, preserve required shutdown behavior and migrate state transactionally. Never silently fetch a floating dependency at startup.

**UPD03.** Changes to a protected component or its configuration trigger the relevant reference comparison. A smaller model, new daemon flag or changed Tor/cover default is a security-relevant change, not merely a performance tweak.

**UPD04.** Rollback must preserve current financial truth. If an older binary cannot read newer state, keep a compatible recovery path rather than restoring an old wallet journal.

**UPD05.** Explain distribution and maintenance exposure. A download server may learn that the app was downloaded; the product must not turn that observation into a stable identity accompanying private requests.

**UPD06.** Uninstall stops services and identifies balance/pending work. It offers recovery or withdrawal and separates financial state from conversation deletion. Removing the app is not a withdrawal.

## 11. Mandatory release evidence

All of these are initial-release gates for the complete protected product. Partial integrations, a local-only demo, fixture-only payments or accurate disclaimers cannot satisfy a missing gate.

| ID | Test | Required evidence |
| --- | --- | --- |
| A01 | Reproduce the reference | Immutable baseline, actual policies, versions/model, deployment and representative successful tasks are recorded |
| A02 | Clean Mac installation | GUI and authorized agent setup both reach the complete working stack without manual dependency installation |
| A03 | GUI/CLI equivalence | Both use the same manifest, controller, session state and single payment writer |
| A04 | Content and usefulness | Matched tasks compare rewriting, sent fields, history and useful outcomes; meaningful differences are investigated |
| A05 | Whole-agent containment | Disallowed files, host access, privileged operations and cross-session state remain inaccessible |
| A06 | Complete routing | Main/auxiliary requests, tools, children, DNS and alternative protocol attempts cannot obtain a direct bypass |
| A07 | Conversation isolation | Repeated prompts, concurrent callers, switching and restart preserve reference identity/history separation |
| A08 | Cover behavior | Observed schedules and startup/shutdown/interruption behavior match the qualified policy; limits do not silently reduce it |
| A09 | Failure and pause | Model/daemon/route failures, Pause, Quit, sleep/wake and crashes do not cause fallback or lose uncertainty |
| A10 | Local API authority | Forged sessions, unrelated web pages and ordinary task credentials cannot administer policy, wallets or the host |
| A11 | Paid operations | Actual funding, usage, fees, settlement and withdrawal work against the qualified deployment |
| A12 | Financial interruption | Lost replies, duplicate client retries, process crashes and backup restoration do not corrupt or duplicate financial authorization |
| A13 | Fresh-device recovery | An encrypted export restores on another qualified Mac, reconciles and can spend or withdraw |
| A14 | Wrapper-created leaks | Logs, analytics, renderers, exports, new display fields, host–guest channels and diagnostics add no unauthorized disclosure |
| A15 | Update and rollback | Qualified changes preserve controls and current financial state; mismatches stop safely |
| A16 | Deletion and removal | Active authority is revoked, retained private state is removed appropriately and recovery remains deliberate |
| A17 | Hardware and substitution | Unsupported machines stop clearly; alternative runtimes/models/harnesses cannot inherit approval without evidence |
| A18 | Usability | First-time users install, start, inspect a charge/disclosure, pause and recover without terminal/configuration work |
| A19 | Honest claims | Documentation matches tested scope and known reference limits; no stronger timing claim or partial-workflow parity claim |

### Evaluation rules

Use synthetic or consented data. Compare matched tasks and include adverse cases; account for nondeterministic model output. Structural properties such as blocked direct egress must be enforced, not accepted because no accidental leak happened in a few normal tasks.

For content transformations, define privacy and utility metrics, sample sizes, permitted variation and failure criteria before comparing variants. Investigate meaningful regressions. Do not invent a universal percentage that certifies privacy.

Measure cold start, local rewriting, first response, completion, settlement, CPU/RAM, storage, bandwidth and battery impact on the supported hardware. Installation convenience cannot justify a security downgrade. Slow performance is reported and optimized subject to the same contract.

Have at least five first-time users exercise the complete journey and an interruption/recovery scenario, and record individual failures. This checks usability; it does not replace security verification.

Publish or retain a reviewable evidence package: baseline and release manifests, policies, source changes, test results, relevant network traces, financial recovery results, known gaps and supported versions. No failed or inconclusive protection check counts as a pass.

## 12. Delivery plan

| Stage | Deliverable | Exit condition |
| --- | --- | --- |
| 1. Capture and reproduce | Pi and the actual reference daemon/model/routing/sandbox configuration | Reference tasks and its stated limits are documented and reproduced |
| 2. Automate the stack | Idempotent installer and one supervisor/CLI on the reference environment | Automation preserves versions, policies, behavior and state |
| 3. Package for Mac | Signed app, Linux appliance, required assets and narrow local controls | Complete stack runs on a clean qualified Mac; platform changes pass comparison |
| 4. Add the simple interface | Menu bar, local session, funding/recovery, status and diagnostics | GUI and CLI share behavior; novices complete the supported journey |
| 5. Qualify and release | Full real-service workflow and evidence package | A01–A19 pass; no weaker substitute is used to call the product complete |

Fixtures and test funds support development while production dependencies are unresolved. They must be labeled as such. The paid release is not complete until its actual deployment and recovery are qualified.

The sequencing is deliberate: first automate the known stack, then simplify the interface around it. The product does not wait for a new agent harness, a custom research application or a new anonymity protocol.

## 13. Future work

### F01 — Stronger timing resistance

**Future TODO; not an initial-release requirement.** The October post identifies active timing correlation as a limitation and proposes a specialized mixnet. Preserve the working Tor/cover baseline at launch; investigate stronger transport separately. [S01] [S15]

Any future claim needs a defined attacker, both-direction traffic evaluation, streaming/retries, startup/shutdown, relevant competing traffic and latency/bandwidth/cost measurements. A transport connection succeeding is not evidence of resistance to correlation.

### Other optional changes

- OpenShell as the execution boundary, after reference comparison.
- Hermes or another complete local harness, after full-workflow qualification.
- Different local models or native accelerated inference, after disclosure/utility and boundary evaluation.
- Additional platforms and tasks.
- Stronger local minimization or a new disclosure UI, explicitly distinguished from the reference mechanism.
- Hosted-agent result handoffs with deliberate disclosure semantics; these never make the hosted parent equivalent to the protected local session.
- Qualified local-only workflows, if useful, with separate capability and disclosure claims.

## 14. Definition of done

A non-technical person can install one application, or ask their authorized local agent to do it, and obtain the complete working private-agent setup described by the qualified reference.

They can start and pause it from the menu bar, understand its current state and charges, recover from interruption and device loss, and update it without assembling dependencies or learning its protocols.

The release preserves the reference’s specified protections and useful behavior, with evidence for the Mac adaptations and wrapper. If an essential protection cannot be preserved, the affected configuration does not ship.

**Product statement:** The complete private-agent stack, installed and operated for you, with no reduction in its specified privacy or security protections.

## 15. Sources and evidence limits

Reviewed 29 October 2026. Sources establish upstream capabilities or reported intent, not completed product tests. The user supplied the original October post; it does not contain every reproducible setting. Candidate development snapshots are not automatically the reference or a deployable production bundle.

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

