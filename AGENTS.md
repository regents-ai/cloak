# Regents Cloak: agent instructions

Start Regent work with the workspace's regent-workflow skill
(`/Users/sean/Documents/regent/.agents/skills/regent-workflow/SKILL.md`).
For the Mac app, load the macos skills (`macos-patterns`, `macos-build`,
`macos-release`, `macos-auto-update`, `macos-settings-ui`) before writing Swift.

The contract is [docs/spec-v0.3.md](docs/spec-v0.3.md). Read sections 2, 11
and 12 before any change. Progress lives in [docs/plan.md](docs/plan.md).

## Rules

- Follow the spec's stages in order: capture and reproduce the reference, then
  one supervisor and CLI, then Mac packaging, then the menu-bar interface.
- One implementation. No second engine, runtime abstraction or optional path
  kept "just in case".
- No fallback, ever (spec REF04). When a model, daemon, sandbox, route, cover
  worker or payment prerequisite fails, affected work stops.
- Hard cutover: no shims, aliases, compatibility branches or dual shapes.
- A protection is proven only when its gate in `docs/plan.md` has recorded
  evidence. Never write "protected", "private" or "equivalent" in copy, docs or
  status output beyond what a passed gate shows (spec A19).
- Reconstructed items are labelled `reconstructed` in `reference/baseline.md`
  until the upstream original replaces them.
- Development stand-ins (fixture payments, test funds, a smaller model) are
  labelled as such and never ship in a release manifest.
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
