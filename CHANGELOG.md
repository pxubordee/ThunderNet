# Changelog

## 0.2.0 — 2026-11-13

### Added

- Configuration presets: `Minimal`, `Standard`, `Hardened`
- `ThunderNet.Init()` server/client auto-detection
- `ThunderNet.Event<T>(Net, name, options)` typed helper
- `FireMany` and `FireExcept` broadcast helpers
- Per-lane `MaxQueueDepth` cap with `QueueOverflow` statistics
- `Promise.all` for concurrent requests
- Validator `Literal`, `OneOf`, and `Map` schemas
- Permissions `GroupRank` and `HasAttribute` helpers
- Per-request RPC options: `Timeout`, `MaxAttempts`, `Idempotent`
- Protocol/config handshake with early codec mismatch errors
- Serializer `FallbackToNative` option
- `Net.OnError`, `Net.OnDrop`, and `Net.OnRateLimited` hooks
- Per-event inbound middleware and outbound event middleware
- `OutboundRejected` statistics
- Full API reference and beginner tutorial

### Changed

- Middleware machinery is skipped when no middleware is registered.
- Clients validate protocol version and serializer/compression flags on startup.
- Unreliable event sends default one message per call to respect Roblox's cap.

### Tests

- 186 automated tests passing; strict analysis clean; dev place and `.rbxm`
  package builds verified.

## 0.1.0 — 2026-11-12

### Added

- Typed events, channels, priorities, reliable and unreliable lanes
- Validated protocol, rate limits, permissions, schema and payload checks
- Per-destination batching with fairness and adaptive delay
- RPC with timeouts, backoff, retries, dedupe cache, cancellation
- Middleware, statistics, lifecycle cleanup
- 160-test suite, strict analysis, Roblox Studio Play Solo benchmark sample
- Draggable `.rbxm` package, Wally manifest, MIT license, release workflow
