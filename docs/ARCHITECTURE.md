# Architecture

ThunderNet is a session object (`ThunderNet.Server()` / `ThunderNet.Client()`)
that wires together small, independently tested modules. Everything inbound is
validated before it touches game code; everything outbound is encoded once,
measured, queued per destination and flushed on a heartbeat.

## Module map

| Module | Responsibility |
| --- | --- |
| `Core/Network` | Public API, session lifecycle, wiring, encoding pipeline, stats snapshot |
| `Core/Dispatcher` | Inbound pipeline: structural checks, rate limit, payload/schema validation, middleware, handler dispatch |
| `Core/Protocol` | Wire envelopes, opcodes, flags, strict structural validation |
| `Core/Scheduler` | Frame-driven timer min-heap used by `Net:After` |
| `Core/RequestManager` | RPC pending registry, timeouts, retries, cancellation, dedupe cache |
| `Core/Registry` | Event definitions/handles, request handlers, per-event options |
| `Transport/Reliable` | Thin wrapper over `RemoteEvent` |
| `Transport/Unreliable` | Thin wrapper over `UnreliableRemoteEvent` |
| `Features/Batcher` | Per-destination, per-lane, 5-priority queues with fairness and adaptive flushing |
| `Features/Middleware` | Ordered inbound pipeline with strict `next()` semantics |
| `Features/Serializer` | Optional binary codec for supported types, hardened decoder |
| `Features/Compression` | Pluggable codec registry + tested RLE codec, savings gate |
| `Features/Channels` | Named event grouping with inherited default options |
| `Features/RetryManager` | Pure exponential-backoff + jitter policy |
| `Security/Validator` | Schema DSL and iterative payload security walk |
| `Security/RateLimiter` | Per-player, per-key token buckets |
| `Security/Permissions` | Permission helper functions |
| `Utilities/Signal` | Allocation-free emission, safe disconnect during emit |
| `Utilities/Promise` | Promise with chaining, cancellation and `Await` |
| `Utilities/Janitor` | Reverse-order cleanup for connections/instances/functions |

Dependency direction is acyclic: utilities and types have no internal
dependencies; security and features depend only on utilities/types/core
primitives; `Network` is the only module that knows all of them. `Channels`
depends on `Registry` for types only.

## Outbound path

```
Event:FireClient/FireAll/FireServer
  → Registry validation + default priority
  → Network encoding:
      optional Serializer.Encode (flags bit 1)
      optional Compression.Compress when beneficial (flags bit 2)
      byte measurement for batch budgets
  → Batcher: per-destination reliable/unreliable lane, 5 priority queues
  → Heartbeat Step: fairness-aware batch assembly (size/byte limits)
  → Protocol single envelope or {0, messages} batch
  → RemoteEvent / UnreliableRemoteEvent
```

The same encode → batch path is used for RPC requests, responses and cancels.
Encoded envelopes are marked with flags so retries never re-encode a payload.

## Inbound path

```
Transport OnServerEvent/OnClientEvent
  → Network._handlePacket (timing stats)
  → Dispatcher.HandlePacket
      1. Protocol.Unpack: packet/table, opcode, array lengths, flags, names,
         request ids, batch counts, no nested batches
      2. per-envelope token bucket (server side)
      3. lane rules: requests/responses/cancels reliable-only; unreliable
         events must be declared unreliable by the server
      4. decode payload (decompress → deserialize)
      5. per-event RateLimit and Permission (server)
      6. Validator.CheckPayload (supported types, finite numbers, key types,
         byte and depth limits, cycles/shared refs)
      7. event Schema/Validate
      8. Middleware.Run
      9. signal fire (events) or request handling/dedupe (RPC)
```

Each envelope is executed under `pcall`; an internal error drops that message,
counts `Errors`, logs, and (for requests) returns an error response so clients
are never left hanging.

## Frame loop

One `RunService.Heartbeat` connection per session runs, in order:

1. `Scheduler:Step(now)` — `Net:After` timers.
2. `RequestManager:Step(now)` — retry scheduling and timeouts (may enqueue).
3. `Batcher:Step(now)` — flush due lanes.

Ordering means anything enqueued by timers or retries is flushed in the same
frame. Batcher timestamps use `os.clock()`.

## RPC design

- Request ids are generated per manager (`c<hex>-<counter>` / `s<hex>-<counter>`)
  and validated on receipt.
- A pending record tracks destination, attempts, wait state and next deadline.
- On timeout with attempts left, a retry is scheduled after exponential backoff
  with jitter; the same envelope is re-sent.
- Receivers cache completed responses per request id per player (`DedupeTtl`,
  `DedupeMaxEntries`) and replay the cached response for duplicates, so
  non-idempotent handlers do not run twice for retries.
- Cancels are remembered briefly so a request that arrives after its cancel is
  answered `CANCELLED` without executing.
- Server→client requests verify that the responder is the destination player.
- Player removal rejects pending work and clears dedupe/cancel state.

## Lifecycle and memory

All listeners (remotes, heartbeat, player removal) are held by a Janitor.
`Destroy` disconnects them, destroys scheduler batches/requests/registry, and
(on the server) removes the remotes folder. Queues, dedupe caches, pending
requests and rate buckets are bounded or cleared on player removal/destroy; the
batcher keeps no unbounded retry structures.

## Deliberate trade-offs

- **String channel names on the wire.** Simple, robust and avoids a
  client/server id handshake. Roblox string serialization is efficient; local
  registry lookups are table lookups.
- **Arrays for envelopes.** Smaller than string-keyed tables and cheap to
  validate positionally.
- **One flush per frame by default.** A message waits at most one frame; the
  batcher never sleeps in a background loop.
- **Per-player `FireAll`.** Guarantees destination isolation and per-player
  batching; a native broadcast fast-path is a possible future optimization.
- **Unreliable messages default to one per call.** Roblox caps
  `UnreliableRemoteEvent` payloads (~900 bytes); batching them caused engine
  drops in real-play testing, so `UnreliableBatchSize` defaults to 1 and
  `UnreliableMaxBytes` to 900. Batching is opt-in.
- **Dedupe TTL.** Bounded memory at the cost of very late replays potentially
  re-executing; keep the window above your retry horizon.
- **RLE compression.** Simple, bounded and tested rather than a custom
  compressor; gated on measured savings and opt-in.
