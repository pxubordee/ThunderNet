# Benchmarks

> **Looking for a plain-language version?** See
> [Benchmarks, Explained Simply](../BENCHMARKS-SIMPLE.md) for a beginner-friendly
> explanation of these results.


## What was measured

`scripts/bench.sh` runs the framework on the **Luau CLI simulated Roblox
environment** (`tests/cli/RobloxShim.luau`): same Luau sources, fake DataModel,
fake `RemoteEvent`/`UnreliableRemoteEvent` dispatch, deterministic time,
single process. Timing uses the real `os.clock` of the runner process.

Measured on macOS arm64 with the homebrew `luau` build in this repository.
These are CPU-only numbers. They do **not** include Roblox engine scheduling,
replication, bandwidth or network latency.

Command:

```bash
./scripts/bench.sh
```

## Current results

| Benchmark | ops | ms | ops/sec | Notes |
| --- | ---: | ---: | ---: | --- |
| Signal emit (1 handler) | 500,000 | 23.29 | 21.5M | no allocation in emit |
| Middleware chain (5 layers) | 100,000 | 78.37 | 1.28M | includes context allocation |
| Batcher enqueue+flush | 100,000 | 23.29 | 4.29M | 64 batches of ≤128 |
| Serializer encode (nested) | 50,000 | 346.13 | 144k | 228 B result |
| Serializer decode (nested) | 50,000 | 243.44 | 205k | bounds-checked |
| RLE compress 10 KB runs | 2,000 | 713.52 | 2.8k | 10 KB → 120 B |
| RLE decompress 10 KB runs | 2,000 | 24.48 | 82k | output cap enforced |
| Payload security walk | 100,000 | 124.15 | 805k | byte+depth+type limits |
| Network server→client event | 10,000 | 25.78 | 388k | 10,000 delivered, 79 batches |
| Native RemoteEvent baseline (simulated) | 10,000 | 0.78 | 12.9M | raw fake transport, no validation/batching |
| Native RemoteEvent large payload (simulated) | 2,000 | 0.20 | 9.91M | raw transport only |
| Native RemoteEvent client→server (simulated) | 10,000 | 0.56 | 18.0M | raw transport only |
| Native UnreliableRemoteEvent (simulated) | 5,000 | 0.44 | 11.5M | raw transport only |
| Network client→server event | 10,000 | 26.34 | 380k | rate+payload validation included |
| Network unreliable event | 5,000 | 12.87 | 388k | over UnreliableRemoteEvent |
| Network large payload (native) | 2,000 | 5.16 | 387k | serializer+compression off |
| Network large payload (serialized+compressed) | 2,000 | 186.71 | 10.7k | savings 3,944,000 bytes |
| RPC round-trip | 500 | 3.22 | 155k | batching + dedupe enabled |

## Interpretation

- The native baselines are raw fake-remote dispatch only. They quantify the
  overhead of ThunderNet's validation, batching and dispatch layers in the
  simulation (~30–47× fewer messages/sec than a bare transport that does no
  work); they are **not** real network comparisons and no real-world multiplier
  is claimed. In Roblox, actual sends are dominated by engine networking.
- End-to-end simulated event delivery costs single-digit microseconds per
  message in this environment, including rate limiting, structural validation,
  payload security walk, middleware and signal dispatch.
- The binary serializer is fast enough for batched payloads but is opt-in: for
  small/native payloads it adds CPU and bytes. Enable it when compression or
  predictable byte accounting matters.
- RLE compression is CPU-heavy relative to modern compressors (≈0.36 ms per
  10 KB of runs) and only helps for repetitive data. In the large-payload
  comparison it saved 3.94 MB total across 2,000 messages but reduced simulated
  delivery throughput from ~387k/s to ~10.7k/s. It is opt-in and gated by
  measured savings; do not enable it blindly.
- Memory/allocation figures are not reported here because the shim cannot
  measure real engine allocations or garbage-collection pressure reliably.
  Cleanup is covered by tests (queue depth, pending requests, dedupe caches).


## Roblox Studio engine measurements (Play Solo, one sample)

Run through Roblox Studio's MCP on a baseplate place in **Play Solo** (local
server + real `RemoteEvent`/`UnreliableRemoteEvent` instances), 2026-11-12.
One sample only; Studio scheduling and GC cause variance, so re-run before
treating differences as significant.

| Benchmark | ops | ms | rate | Notes |
| --- | ---: | ---: | ---: | --- |
| Signal emit (1 handler) | 100,000 | 14.48 | 6.91M/s | no allocation in emit |
| Middleware chain (5 layers) | 30,000 | 32.47 | 924k/s | context allocation included |
| Batcher enqueue+flush | 30,000 | 7.90 | 3.80M/s | 128-message batches |
| Serializer encode | 3,000 | 12.68 | 237k/s | 228 B result |
| Serializer decode | 3,000 | 9.36 | 320k/s | bounds-checked |
| RLE compress 10 KB | 200 | 31.97 | 6.25k/s | 10 KB → 120 B |
| RLE decompress 10 KB | 200 | 4.54 | 44.0k/s | output cap enforced |
| Payload security walk | 30,000 | 29.56 | 1.01M/s | byte+depth+type limits |

| Path | Delivered | Client/server span | Rate | Notes |
| --- | ---: | ---: | ---: | --- |
| Server → client · ThunderNet reliable | 2,000/2,000 | 6.08 ms | 329k/s | enqueue 2.35 ms; 64-msg batches |
| Server → client · native reliable | 2,000/2,000 | 16.82 ms | 119k/s | raw loop, no validation |
| Server → client · ThunderNet unreliable | 1,000/1,000 | 250.34 ms | 4.0k/s | one message per call + 64-batch/frame cap |
| Server → client · native unreliable | 1,000/1,000 | 13.93 ms | 71.8k/s | raw loop |
| Server → client · serializer+RLE 2 KB | 300/300 | 25.28 ms | 11.9k/s | enqueue 33.32 ms |
| Client → server · ThunderNet reliable | 2,000/2,000 | 9.10 ms | 220k/s | client enqueue 8.73 ms |
| Client → server · native reliable | 2,000/2,000 | 1.71 ms | 1.17M/s | raw loop |
| Client → server · ThunderNet unreliable | 1,000/1,000 | — | — | client enqueue 2.96 ms |
| Client → server · native unreliable | 1,000/1,000 | — | — | client enqueue 1.62 ms |
| Client → server · serializer+RLE 2 KB | 300/300 | — | — | client send 40.5 ms, savings 592,283 B |
| RPC sequential | 50/50 | 2,483 ms | 20.1/s | ~50 ms per round-trip, frame-bound |
| RPC burst (300 concurrent) | 300/300 | 52.05 ms | 5,763/s | batching + dedupe enabled |

Important context:

- Play Solo means a local server in the same Studio process: no real network
  latency or bandwidth. Use gameplay telemetry for those.
- Native baselines are raw send/receive loops with no validation, batching,
  retries or rate limits. ThunderNet numbers include its security and framing
  work. Burst spans also depend on batching and frame scheduling, so e.g. the
  native small-event span being slower than ThunderNet in this sample shows how
  noisy single-run burst measurements are.
- The unreliable lane is deliberately one message per call (Roblox caps
  unreliable payloads ~900 bytes). Its burst throughput (~4k/s) is limited by
  the batcher's 64-batches-per-step cap, not by the engine.
- RPC sequential round-trips reflect ~50 ms of Play Solo frame pacing per
  request; the concurrent burst shows the throughput-oriented path.

This engine run also caught a production bug: batching 64 unreliable messages
into one `UnreliableRemoteEvent` call exceeded Roblox's payload cap and the
engine dropped the packets. ThunderNet now defaults unreliable batches to one
message (`UnreliableBatchSize = 1`, `UnreliableMaxBytes = 900`), with opt-in
batching for advanced users. The CLI suite gained two regression tests for this.

## Engine-side benchmarks (script for repeated runs)

`benchmarks/StudioBenchmarks.server.luau` measures, in Roblox Studio:

- native `RemoteEvent:FireClient` call cost vs ThunderNet enqueue + one
  heartbeat flush,
- serializer encode/decode cost,
- RLE compress/decompress cost.

Run it in Play Solo with at least one player (Rojo sync the project or copy the
script into `ServerScriptService`). Results depend on the machine and Studio
version. Real-network measurements (latency, bandwidth, loss) require gameplay
telemetry and are intentionally not claimed.

## Comparing against native RemoteEvent usage fairly

1. Use the same payload tables and the same number of messages.
2. Compare equal delivery semantics: native per-message sends vs ThunderNet
   batching is not apples-to-apples; also compare ThunderNet with
   `MaxBatchSize = 1`.
3. Measure both CPU and delivered-message counts; a faster sender that drops
   messages is not a win.
4. Test multiple payload sizes (small/medium/large repetitive) and frequencies.
5. For unreliable traffic, compare against `UnreliableRemoteEvent` only.
6. Re-run after framework changes; numbers in this file are historical.
