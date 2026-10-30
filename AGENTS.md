# Regents Cloak: agent instructions

Start Regent work with the workspace's regent-workflow skill
(`/Users/sean/Documents/regent/.agents/skills/regent-workflow/SKILL.md`).
For any Mac app work, load the skills from
[macos-app-skills](https://github.com/fayazara/macos-app-skills) that the work
touches, plus `write-swift` for all Swift. Sean requires them.

| Skill | Load for | Spec limits that win over the skill |
| --- | --- | --- |
| `macos-patterns` | Every piece of app code: menu bar, activation policy, windows, launch at login | Start at login stays optional and keeps a deliberate pause (section 7) |
| `macos-build` | Every compile check, through `xcodebuild` | Run builds one at a time, niced |
| `macos-settings-ui` | The utility windows: settings, activity, balance, updates, recovery | Few words on screen; technical detail only on demand |
| `macos-notch-ui` | The running or paused indicator on Macs with a notch, beside the menu-bar control | The menu-bar control stays the main interface; the indicator never shows prompts or amounts |
| `macos-auto-update` | Updates, with Sparkle | UPD01 to UPD02 and NET09: an update check is maintenance traffic, never carries task content, and an update never silently resumes spending |
| `macos-release` | Signed, notarized releases (stages 3 and 5) | MAC06 Developer ID; publishing needs a GitHub remote Sean creates, and signing keys are Sean's |

Interface copy also follows `better-writing`, `better-accessibility` and
`apple-design`.

The contract is [docs/spec-v0.4.md](docs/spec-v0.4.md). Read sections 1, 4, 7,
11 and 12 before any change. Progress lives in [docs/plan.md](docs/plan.md).

## Rules

- Follow the spec's stages in order: freeze the experiment, build the local
  rewrite path, check feasibility, qualify the substitution, package, release.
- The rewriter is one native MLX worker on macOS, reached from the guest only
  through one authenticated adapter that carries the daemon's chat request and
  reply. Exactly one model, loader and configuration ships: no model picker,
  no switching by hardware, no second rewrite stage.
- The daemon's instruction bytes, request fields, reply checks and limits stay
  exactly as captured in `reference/rewriter-contract.md`. No prompt tuning,
  placeholders, fine-tuning, pruning, expert streaming or speculative decoding
  in a candidate.
- Model files load only from local files matching `reference/models.json`;
  never fetch from a model hub at runtime.
- One implementation. No second engine, runtime abstraction or optional path
  kept "just in case".
- No fallback, ever (spec REF04). When a model, daemon, sandbox, route, cover
  worker or payment prerequisite fails, affected work stops.
- Hard cutover: no shims, aliases, compatibility branches or dual shapes.
- A protection is proven only when its gate in `docs/plan.md` has recorded
  evidence. Never write "protected", "private" or "equivalent" in copy, docs or
  status output beyond what a passed gate shows (spec A19).
- Reconstructed items stay labelled `reconstructed` in `reference/baseline.md`.
  Sean ruled on 29 October that the reconstruction is the Regents reference;
  nobody waits for or swaps in the unpublished original.
- Development stand-ins (fixture payments, test funds, a small model for
  building the worker) are labelled as such and never ship in a release
  manifest.
- The reference model runs only on rented or borrowed high-memory hardware,
  and rented hardware sees approved synthetic fixtures only.
- Real funding and wallet work is protected: it needs Sean's explicit go.
- Tests come after a feature works; unit and functional tests only. No smoke,
  integration or exact-wording tests unless Sean asks.
- Python runs through `uv`. Never read `.env` files.
- Delete nothing you did not make; stop only processes you started, by pid.
- Keep memory and disk use low: check free RAM and disk before any large
  download, VM image or model weights.

## Git and tickets

This repository is local only; there is no remote until Sean creates one.
Agents commit their own work here with a message saying what changed and why,
and add a CHANGELOG entry in the same commit.

Tickets use `bd`:

```bash
bd ready                 # open work with nothing blocking it
bd show <id>             # one ticket
bd update <id> --claim   # take a ticket
bd close <id>            # finish a ticket
```
