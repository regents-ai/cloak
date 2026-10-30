# Rewriter contract (spec section 7, A20)

What the daemon sends to the local rewriter and what it accepts back. The
native worker and guest adapter must keep every item here unchanged. Recorded
30 October 2026 from `zkapi-clientd/internal/rewriter/rewriter.go`.

## Same at both pins

The rewriter files are byte-identical at the post's commit (`vbuterin/zkapi`
`0fb263b0`) and the spec's later snapshot (`ethereum/zkapi` `eac5f906`):

| File | sha256 |
| --- | --- |
| `internal/rewriter/rewriter.go` | `ad5609c25a483adc19db15391df2b019cc20110796fe12e0d97d0a73df8b7067` |
| `internal/rewriter/instruction_eval_test.go` | `8581ba4116e7b843c1839928aff1fb657586d29e28b97cd2e88fa507fa52b8a2` |
| `docs/REWRITER.md` | `052bb922292603dc4638a3b3d76d1e74252a6ae4d0aa8fe587c8544440d8d9af` |
| `docs/REWRITER_EVALUATION.md` | `3c522b758645d6ca0519f2599c3520b50102f40df5264d873b3b15364e83a1dd` |

## Request

`POST <rewriter-url>/v1/chat/completions`, `Content-Type: application/json`,
`Authorization: Bearer <key>` only when a key is configured (the reference
runs with none).

| Field | Value |
| --- | --- |
| `model` | the configured name; the reference uses `qwen3.8-flash-next` |
| `stream` | `false` |
| `temperature` | `0` |
| `max_tokens` | `16384` |
| `messages[0]` | `system`: `DefaultInstruction + "\n\n" + responseContract` |
| `messages[1]` | `user`: `{"texts":[...]}`, one string per text part of the newest user turn |

The system message is 1,376 bytes, sha256
`c95de591e464e6215df0544b7ef03486326ba45f095ea055d2f86e6daf91724b`.
Candidate-specific prompt tuning is not allowed (spec DATA01, DATA04). The
request sets no thinking or reasoning field, so the model's chat template
decides whether the model thinks first. That makes the thinking setting part of
each candidate's frozen configuration ([models.md](models.md)).

Which text is sent: only when the newest message's role is `user`. Plain string
content is one text; for content parts, each non-blank `text` part is one
text, `image_url`, `input_audio` and `file` parts pass through unrewritten, and
any other part type fails the rewrite. The user message is Go's
`json.Marshal` output, which writes `<`, `>` and `&` as `<`, `>` and
`&`; the adapter passes these bytes on unchanged. The reference uses the
default instruction; a configured custom instruction would replace it.

Transport: no proxy, no redirects followed, no keep-alive, TLS 1.2 or later,
10 s to connect, 90 s for the whole call, response headers at most 64 KiB.

## Accepted reply

Anything else fails the rewrite, and the task stops before target inference.
There is no fallback to the original text.

- HTTP 200, body at most 1 MiB.
- Exactly one choice, `finish_reason` `stop`, no `refusal`, and `tool_calls`
  absent, `null` or `[]`.
- `message.content` is exactly one JSON object `{"texts":[...]}`: no other
  fields, nothing after it, and the same number of strings as were sent.
- Every string is non-blank, valid UTF-8, and has no control characters other
  than newline and tab. All strings together are at most 128 KiB.

Input limit: the newest user turn's text parts total at most 128 KiB.

## Reference evaluation

`instruction_eval_test.go` holds the 16 synthetic cases (EVAL01) and the
instruction candidates the author compared. `REWRITER_EVALUATION.md` records
that the author ran them on 16 October against `localhost:8012`, model
`qwen3.8-flash-next`, with at most two calls at once. It does not say which
inference server, quantization, thinking setting or sampling defaults the
server applied; those stay **unknown** in [baseline.md](baseline.md).

## Checking the bytes again

```bash
uv run scripts/fetch_sources.py
shasum -a 256 reference/src/*/zkapi-clientd/internal/rewriter/rewriter.go
```
