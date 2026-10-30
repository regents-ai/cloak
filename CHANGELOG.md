# Changelog

## Unreleased

- Adopted spec v0.4 in place of v0.3: a native Mac rewriter with a smaller
  model, six stages and gates A01 to A26. Plan, rules and readme follow it.
- Stage 1: captured the rewriter contract; it is identical at both daemon pins.
- Stage 1: pinned every file of the reference model, both candidates and their
  vendor checkpoints, with a script that records them without downloading
  weights. Found that the lead conversion splits words differently from Qwen's
  own tokenizer and that the challenger conversion has Google's chat template
  from before a fix.
- Stage 1: drafted the evaluation protocol.
- Stage 2: pinned a small development stand-in model (Qwen3.5 2B, 4-bit,
  same model code as the lead) for building the worker, and added a script that
  downloads a pinned model and checks every file. The stand-in is never
  evaluated and never ships.
- Stage 1: proposed values for the evaluation protocol's open items (attacks,
  intervals, confidence, sample size, repeat runs); they need sign-off.
- Recorded Sean's decisions of 30 October: candidates use their conversion's
  weights with the vendor's own tokenizer and chat template; no 32 GB Mac is
  tested, so 32 GB support stays unmet and at most a limited 48 GB pilot is
  possible.
- Stage 2: added the native rewrite worker. It loads a model only after every
  file matches its pin, applies the model's own chat template with the pinned
  settings, decodes greedily, runs one rewrite at a time, and answers in the
  shape the daemon reads. A cancel from the supervisor stops the rewrite; any
  protocol fault stops the worker. Twenty functional checks cover refusals,
  the token limit, cancellation, a second request while busy, bad frames and
  tampered model files.
- Stage 2: added the guest and the host. The guest is a minimal Linux image
  with no network device in which the daemon's own rewrite code calls a small
  adapter; the adapter forwards each request unchanged over one token-checked
  virtio socket to the host, which relays it to the worker. Sixteen checks
  drive the whole path: unchanged requests, nine kinds of bad reply refused,
  cancellation, the daemon's deadline, and a lost worker. The worker's network
  sandbox is still to come.

- Started the repository for the Regents Cloak Mac app, with spec v0.3, the
  plan and gates A01 to A19.
- Stage 1: pinned the reference sources (the post's zkAPI daemon commit, the
  spec's later snapshot, Pi 1.3.0) with a fetch script that verifies every pin.
- Stage 1: rebuilt the daemon at the post's commit; its own checks pass.
- Stage 1: reconstructed the unpublished Pi sandbox wrapper and a Linux host to
  test it. Found that programs which skip torsocks reach the internet directly.
- Stage 1: the reconstruction is now the Regents reference, by Sean's ruling.
- Agent rules now require the macos-app-skills for all Mac app work, each
  mapped to the stage it serves and the spec limits that win over it.
