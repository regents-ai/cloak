# Reference tasks

Tasks used to compare a candidate build with the reference (REF03, A04).
Synthetic or consented data only.

## T01: Vegan restaurants in Tallinn

The task shown in the post's four screenshots, 16 October 2026.

- **Input:** `find the top 5 best vegan restaurants in Tallinn`
- **Rewrite shown:** `Identify the top 5 vegan restaurants in Tallinn.`, inside
  the daemon's preview labelled `zkapi prompt rewrite — NOT target-model
  thinking`.
- **Tools used:** Pi's bash tool running `curl -Ls --max-time 15..20` against
  visittallinn.ee pages and a Google search URL, then inline `python -` scripts
  that strip HTML and pick out links. Each command finished in about 5 to 6
  seconds.
- **Outcome:** a five-row table (place, reason, best for) with a caveat that
  opening hours could not be verified.
- **Needs from the sandbox:** `curl`, `python3`, a writable `/tmp`, and
  outbound HTTPS for tools.

Status: not yet run on the reconstruction; it needs paid inference.
