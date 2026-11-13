# ThunderNet roadmap

This file keeps the feature ideas honest: what is shipping now, what comes next,
and what is deliberately deferred. ThunderNet's core stays small; heavier
capabilities must be opt-in and measured.

Guiding rule: **faster, simpler, and more features** cannot all increase at
once. We buy speed with batching and fewer calls, buy simplicity with presets
and defaults, and add power behind optional modules and configuration.

## Shipped

- Typed events, channels, priorities and unreliable lanes
- Validated protocol, payload/schema checks, rate limits and permissions
- Per-destination batching with fairness, adaptive delay and reliable/unreliable lanes
- RPC with timeouts, backoff, retries, dedupe cache, cancellation and promises
- Middleware, stats, lifecycle cleanup
- 186-test suite, strict analysis, Rojo build
- Milestone 1: presets, Init/typed helpers, FireMany/FireExcept, queue caps, Promise.all, validator and permission helpers
- Milestone 2 (partial): per-request RPC options, protocol/config handshake validation, serializer native fallback, error/drop/rate-limit hooks, per-event inbound middleware, outbound event middleware
- Roblox Studio Play Solo benchmark sample and beginner-friendly benchmark guide
- Draggable `.rbxm` packaging, MIT license, release workflow

## Milestone 1 — speed, safety and ergonomics (shipped)

Low-risk wins that improve all three goals:

| Item | Goal | Status |
| --- | --- | --- |
| Skip middleware machinery when no middleware is registered | Speed | Done |
| Per-lane queue depth cap with `QueueOverflow` stats | Safety | Done |
| `Preset = "Minimal" \| "Standard" \| "Hardened"` configuration | Simplicity | Done |
| `ThunderNet.Init()` server/client auto-detection | Simplicity | Done |
| `ThunderNet.Event<T>(Net, name, options)` typed helper | Simplicity | Done |
| `FireMany(players, data)` and `FireExcept(player, data)` | Features | Done |
| `Promise.all` for concurrent requests | Features | Done |
| Validator `Literal`, `OneOf`, `Map` | Features | Done |
| Permissions `GroupRank`, `HasAttribute` helpers | Features | Done |

Every network-path change gets unit/integration tests. No performance multiplier
is claimed unless a before/after benchmark is run.

## Milestone 2 — protocol and developer experience

| Item | Why it is not in milestone 1 |
| --- | --- |
| Broadcast fast path (`FireAllClients`) | Planned — needs ordering rules against per-player queues |
| Immediate RPC flush option | Planned — trades burst throughput for latency; needs benchmarking |
| Safe unreliable auto-batching under the ~900-byte cap | Planned — needs careful byte accounting and engine tests |
| Handshake + event/config sync | Partial — protocol/codec validation shipped; event sync pending |
| Per-request options (`Idempotent`, retries, timeout) | Done — Timeout, MaxAttempts, Idempotent |
| Per-event and outbound middleware | Partial — per-event inbound and outbound event sends shipped; RPC outbound middleware pending |
| Error/drop/rate-limit hooks | Done — `OnError`, `OnDrop`, `OnRateLimited` |
| Serializer native fallback | Done — `FallbackToNative` with a one-time warning |
| Debug overlay | Planned — separate client UI module |
| RPC batching/Promise batch helpers | Promise.all shipped; further batch helpers planned |

## Milestone 3 — larger features

| Item | Notes |
| --- | --- |
| Channel subscriptions | Server publishes to subscribed clients; requires subscription state |
| Metrics history/export | Sampled counters, time series, optional external logging |
| Chunked large payloads | Splits payloads beyond a single remote call; ordering and reassembly |
| Fast LZ-style codec | New codec behind the tested codec interface; benchmark CPU vs savings |
| Rich permission policies | Group/user/attribute composition and policy helpers |

## Milestone 4 — evaluate before building

| Item | Condition |
| --- | --- |
| State replication/delta layer | Only if event/RPC primitives prove insufficient; large subsystem |
| Interest management | Only after profiling shows broadcast volume is the bottleneck |
| Custom binary wire protocol | Only if native Roblox serialization is measured as the bottleneck |
| Studio inspector plugin | Useful, but separate tooling project |
| Parallel codec workers | Only if heavy payload profiling proves Actor overhead is worthwhile |

## Non-goals

- Making Roblox's internet faster; real latency and bandwidth require live
  telemetry.
- Replacing server-authoritative game logic with framework checks.
- Adding features that cannot be tested in the CLI suite and, where relevant,
  Roblox Studio.
- Claiming speedups from simulation alone.
