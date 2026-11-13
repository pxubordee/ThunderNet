# Changelog

## 0.3.0 — 2026-11-13

### Security

- Added a packet-level token bucket before `Protocol.Unpack`, so malformed
  packet floods consume the same rate-limit budget as valid traffic. The packet
  budget is separate from the message budget (`PacketRate`/`PacketBurst`,
  defaulting to `max(Rate, 300)` / `max(Burst, 600)`) so high frame-rate batching
  is not throttled.
- Bound RPC dedupe entries to the request channel. A replayed request id on a
  different channel is now dropped as `REQUEST_ID_CONFLICT`.
- Added in-flight duplicate suppression: a duplicate request arriving while the
  original handler is still executing is dropped as `REQUEST_IN_FLIGHT`.
- Added regression tests for both fixes.

### Added

- Branding constants: `ThunderNet.DisplayName` (`"ThunderNet For Roblox"`) and
  `ThunderNet.FullName` (`"ThunderNetworking"`).
- The full MIT notice is embedded in the distributed `.rbxm` as the `LICENSE`
  StringValue.
- Root `SECURITY.md` with private reporting guidance, supported versions and an
  audit disclaimer.
- `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, issue/PR templates and Dependabot
  configuration for GitHub Actions.
- Release checksum asset (`ThunderNet-<version>.rbxm.sha256`) and build
  provenance attestation.
- Release notes now include install steps, checksum verification, license and
  security links.

### Changed

- CI and release workflows pin GitHub Actions by commit SHA, download Rojo and
  Luau with verified SHA-256 checksums, and use least-privilege permissions.
- README and documentation use the display name **ThunderNet For Roblox** and
  full name **ThunderNetworking.**
- Documented the corrected inbound check order and the new RPC drop codes.
- The release workflow re-runs the full test/analysis/package check before
  publishing.

### Tests

- 190 automated tests passing; strict analysis clean; dev place and `.rbxm`
  package builds verified.
- The new package embeds the MIT `LICENSE` child; Studio smoke testing of the
  v0.3.0 artifact is a release checklist step.

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
- Release `.rbxm` smoke-tested in Roblox Studio Play Solo (event delivery,
  schema validation and RPC).

## 0.1.0 — 2026-11-12

### Added

- Typed events, channels, priorities, reliable and unreliable lanes
- Validated protocol, rate limits, permissions, schema and payload checks
- Per-destination batching with fairness and adaptive delay
- RPC with timeouts, backoff, retries, dedupe cache, cancellation
- Middleware, statistics, lifecycle cleanup
- 160-test suite, strict analysis, Roblox Studio Play Solo benchmark sample
- Draggable `.rbxm` package, MIT license, release workflow
