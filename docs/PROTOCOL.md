# Wire protocol

The protocol is a compact array format carried as the single argument of
Roblox remotes. The framework version is not embedded in packets: the server
and client must run the same ThunderNet version and matching
serializer/compression configuration. Rolling protocol changes require a
coordinated release.

## Opcodes

| Opcode | Name | Direction | Reliability |
| ---: | --- | --- | --- |
| 0 | Batch | any | matches lane |
| 1 | Event | any | reliable or unreliable (unreliable only if declared) |
| 2 | Request | any | reliable only |
| 3 | Response | any | reliable only |
| 4 | Cancel | any | reliable only |

## Envelope layouts (array indices)

```
Event:    { 1, channel, data [, flags] }
Request:  { 2, channel, requestId, data [, flags] }
Response: { 3, requestId, ok, payloadOrError [, flags] }
Cancel:   { 4, requestId }
Batch:    { 0, { envelope, ... } }
```

- `channel`: printable ASCII, 1..`MaxNameLength` (default 128), no control
  bytes. Event names are developer-defined; clients cannot invent server
  events.
- `requestId`: 1..`MaxRequestIdLength` (default 64) characters from
  `A-Z a-z 0-9 . _ -`. Generated ids are unique per session manager.
- `data`: any Roblox-compatible payload; structurally validated on receipt.
- `ok`: boolean. `true` responses carry a result payload; `false` responses
  carry an error table `{ Code: string, Message: string }` and must not carry
  encoding flags.
- `flags`: integer bitmask, present only when non-zero:
  - bit 1 (1): payload is serializer-encoded (must be a string)
  - bit 2 (2): payload is compressed (must be a string)
  Both bits may be set (compress after serialize).
- Batches carry 1..`MaxBatchMessages` (default 128) envelopes and cannot be
  nested. A single message is sent as a bare envelope (no wrapper).

## Validation rules (all rejected before dispatch)

- Packet must be a table with a numeric opcode.
- Envelope array length must exactly match its opcode (plus optional flags).
- Unknown opcodes, nested/empty/oversized batches, non-table messages reject.
- Channel names and request ids must satisfy the constraints above.
- Flags must be an integer 0..3; encoded payloads must be strings; error
  responses cannot carry flags.
- Unreliable lane: only Event envelopes; the server additionally requires the
  event to be declared `Unreliable = true`. Requests/responses/cancels arriving
  on the unreliable lane are dropped.
- Payloads: only supported value types, finite numbers, string/number table
  keys, no cyclic/shared tables, byte and depth limits (defaults 64 KiB / 8).
- Requests are deduplicated by `(player, requestId)`; cached responses are
  replayed without executing the handler again.

## Request lifecycle

```
Client                          Server
  |- Request(channel, id, data) ->|
  |                               |-- validate, dedupe check
  |                               |-- handler executes once
  |<- Response(id, true, result) -|
  |-- (timeout, attempts left) retry same id --> (cached response replay)
  |-- (timeout, attempts exhausted) reject TIMEOUT + Cancel(id) -->
  |- Cancel(id) ----------------->|-- remembered briefly; late request is
  |                               |   answered CANCELLED without execution
```

Backoff: delay before retry N is `min(BackoffMax, BackoffBase * 2^(N-1))`
multiplied by a jitter factor in `[1 - Jitter, 1 + Jitter]`. `MaxAttempts`
bounds retries; nothing retries forever.

Error codes used by the framework: `TIMEOUT`, `CANCELLED`, `REJECTED`,
`MIDDLEWARE_INCOMPLETE`, `RATE_LIMITED`, `INVALID_PAYLOAD`, `NO_HANDLER`,
`HANDLER_ERROR`, `PLAYER_LEFT`, `DESTROYED`, `PERMISSION_DENIED`.

## Lane semantics

- Reliable lane preserves ordering per `(destination, priority)` queue and is
  used for gameplay state, events with semantics, and all RPC traffic.
- Unreliable lane is for transient, frequently updated data. Ordering and
  delivery are not guaranteed; the framework only guarantees FIFO inside a
  queue before Roblox's unreliable delivery. Because Roblox caps an
  `UnreliableRemoteEvent` call (~900 bytes), ThunderNet defaults to one
  message per unreliable call and exposes `UnreliableBatchSize` /
  `UnreliableMaxBytes` for explicit opt-in batching.
- The framework never promotes unreliable messages to reliable or vice versa.

## Security ordering

Cheap structural checks and rate limiting run before payload decoding;
decode/serializer bounds prevent decompression bombs from allocating beyond
configured limits; schema checks run before middleware; user middleware runs
before handlers. See [SECURITY.md](SECURITY.md).
