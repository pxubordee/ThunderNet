# Security model

## Trust boundary

- The server is trusted.
- Every client is untrusted and can send arbitrary packets, malformed tables,
  duplicate requests, forged ids, unreliable traffic and oversized payloads.
- Roblox's transport provides delivery and origin identity (the server sees the
  sending `Player`); it does **not** validate payloads or game meaning.
- ThunderNet is not an anti-cheat system. It provides the safety envelope;
  your handlers must re-derive damage, currency, inventory, ownership, prices,
  cooldowns and permissions from server state.

## Inbound checks (server), cheapest first

1. **Rate limit** — per-envelope token bucket, default 120/s burst 240 per
   player. Requests that are limited receive a `RATE_LIMITED` response.
2. **Structural validation** — opcode, exact array lengths, printable ASCII
   names, request-id charset/length, flags, batch size, no nested batches.
3. **Lane enforcement** — RPC traffic must be reliable; unreliable events must
   be declared unreliable by the server.
4. **Payload decode bounds** — decompression output capped by
   `MaxDecompressedBytes`; serializer decode is bounds-checked and rejects
   trailing/truncated data.
5. **Payload structural walk** — supported types only, finite numbers,
   string/number keys, byte limit (`MaxBytes`), depth limit (`MaxDepth`),
   cyclic/shared references rejected. Iterative, so hostile nesting cannot
   overflow the stack.
6. **Per-event rate limit** (optional) — a second token bucket keyed by event
   name.
7. **Permission** (optional) — server-side function receives `(player, data)`.
8. **Schema / custom Validate** — runtime checks for the payload shape.
9. **Middleware** — authentication/authorization hooks, payload rejection.
10. **Handler** — executed under `pcall`; throws become `HANDLER_ERROR` without
    leaking internal error text to the client.

Malformed packets are dropped and counted; they do not raise errors to the
transport or stop later traffic.

## RPC safety

- Unique, validated request ids with strict charset and length.
- Duplicate requests replay a cached response for `DedupeTtl` seconds instead of
  re-executing the handler. **This is the primary protection for non-idempotent
  operations under automatic retries.**
- Retry count is bounded (`MaxAttempts`); delays grow exponentially with jitter.
- Responses to server-originated requests are only accepted from the destination
  player.
- Cancellation prevents a request from starting if the cancel arrives first.
- Pending entries and caches are evicted/cleared on player removal and destroy.

### Dedupe trade-off

The dedupe cache is bounded (`DedupeMaxEntries`) and time-limited. A retry that
arrives after eviction/TTL can execute again. Keep `DedupeTtl` comfortably
larger than the worst-case retry window and prefer idempotent handlers for
operations where a late duplicate would be harmful.

## Limits and defaults

| Limit | Default | Purpose |
| --- | ---: | --- |
| `RateLimit.Rate` / `Burst` | 120 / 240 | flood protection |
| `Payload.MaxBytes` | 65,536 | payload size |
| `Payload.MaxDepth` | 8 | nesting depth |
| `Limits.MaxBatchMessages` | 128 | batch amplification |
| `Limits.MaxNameLength` | 128 | channel names |
| `Limits.MaxRequestIdLength` | 64 | request ids |
| `Compression.MaxDecompressedBytes` | 1,048,576 | decompression bombs |
| `Serializer` limits | 1 MiB / depth 16 | encoded payload bounds |
| `Request.DedupeMaxEntries` | 256 | per-player dedupe cache |
| `Request.MaxAttempts` | 3 | retry budget |

All config values are validated; invalid settings throw before remotes are
created.

## Client-side posture

The client validates that inbound packets are structurally sound and bounds
payload decoding, so a buggy server cannot crash clients with malformed data.
Client middleware exists for UI/debug policies; it is not a security boundary.

## What ThunderNet deliberately does not do

- Validate game rules (damage math, prices, ownership) — your server code must.
- Encrypt traffic — Roblox handles transport security.
- Hide payloads from exploiters — clients can read what they receive.
- Provide anti-cheat, movement validation or economy systems.
- Measure real network ping/bandwidth — statistics are CPU/payload estimates.

## Operational recommendations

- Run with `Stats = true` during development and watch `RateLimited`,
  `PayloadRejected`, `DroppedPackets`, `MalformedPackets` and `Retries`.
- Keep request handlers fast and non-yielding; hand long work to a task and
  return promptly (or explicitly reject).
- Prefer the reliable lane for anything that changes state; use unreliable only
  for transient cosmetics.
- Log rejections server-side (`warn`) rather than trusting client-side logs.
- Treat every client-provided value as a *request*, never a fact.
