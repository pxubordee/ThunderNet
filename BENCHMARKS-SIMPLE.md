# ThunderNet Benchmarks, Explained Simply

*For designers, producers, and anyone who doesn't want to read raw performance tables.*

## If you only read one paragraph

ThunderNet is a messaging system for Roblox games. We tested how many messages
it can process on a test machine, both in a simulation and inside Roblox Studio.
The short version: **it comfortably handles far more messages per second than a
normal game sends**, and the extra safety/organizing work costs a little CPU per
message. It does **not** make the internet faster, and "native Roblox remotes"
look faster in tests because they skip all the checking and sorting. Think of it
as comparing a bare hand-off with a courier service that sorts, checks and
tracks packages.

---

## What is ThunderNet, in one minute?

Games constantly send little messages between the server and players:

- "You hit the monster for 10 damage."
- "Your inventory changed."
- "Here is a new position for the effect."
- "Did my purchase go through?"

Roblox gives you a bare tool for this (`RemoteEvent`). ThunderNet wraps that
tool with useful things a real game needs:

- checking that messages are safe and not oversized,
- grouping messages into fewer network calls (batching),
- handling "ask a question, get an answer" requests,
- retrying lost requests safely,
- rate limiting spam,
- keeping statistics.

All of that takes a bit of computer work. The benchmarks measure whether that
work is cheap enough in practice.

---

## How we tested

### 1. A simulation on a computer (the fast, repeatable test)

We ran the exact ThunderNet code on a laptop with a pretend Roblox environment.
This is great for repeating tests and comparing versions, but it does not know
Roblox's real rules (that matters — see "The bug that real testing caught").

### 2. Roblox Studio, Play Solo (the realistic test)

We used Roblox Studio with a real local server and real Roblox remote objects.
This measures the actual engine's CPU work. It is still **not** the internet:
the server and player are on the same computer. Real ping and bandwidth only
show up with real players online.

All numbers below are from the Roblox Studio run unless stated otherwise.

---

## The one big idea

**Sending a message has two costs:**

1. **CPU time** — sorting, checking, packing and unpacking the message.
2. **Network calls** — every separate remote call has overhead.

ThunderNet deliberately spends a little more CPU to:

- bundle many game messages into one network call (fewer calls),
- check data before trusting it (safer),
- keep receipts for requests (more reliable).

The benchmarks ask: *is that extra CPU cheap enough to be worth it?* For normal
game traffic, the answer is yes by a very large margin.

---

## Plain-language results

### Quick visual summary (shorter bars are better)

Each chart compares the **same amount of work**. Bar lengths are scaled within
that chart only, so don't compare a bar from one chart with a bar from another.
"Native raw" means bare Roblox remotes with no checks, batching or receipts.

**2,000 ordinary game updates — total time to finish**

```text
Server → player
ThunderNet   ████████░░░░░░░░░░░░░░░░   0.006 s   (6 ms)
Native raw   ████████████████████████   0.017 s   (17 ms)

Player → server
Native raw   ████░░░░░░░░░░░░░░░░░░░░   0.0017 s  (1.7 ms)
ThunderNet   ████████████████████████   0.0091 s  (9.1 ms)
```

Both ThunderNet paths finish 2,000 updates in **under one hundredth of a
second**. The first group's native timing was unusually slow in this one sample
(burst timing in Studio is noisy); the second group shows the expected pattern:
native raw is faster because it does almost no work. Do not read either chart as
"ThunderNet beats Roblox's transport".

**CPU time for one message** (lower is better)

```text
Native raw (player → server)   ████░░░░░░░░░░░░░░░░░░   0.85 µs
ThunderNet (player → server)   ████████████████████████   4.55 µs
```

ThunderNet spends about **3.7 microseconds more per message** to validate,
queue, batch and safely dispatch it. That still allows roughly 220,000 messages
per second in this test.

**300 questions that need answers (RPC)**

```text
300 questions sent together        ▏                      0.052 s
300 questions one at a time (est.) ████████████████████████  ~15 s
```

One-at-a-time costs about **0.05 s per question** because each waits for the
next game network tick. The 300-at-once burst finishes in **52 ms**, about three
60 FPS frames. "Est." means extrapolated from 50 measured round-trips.

**1,000 quick "throwaway" updates (unreliable lane)**

```text
Native raw   ██░░░░░░░░░░░░░░░░░░░░░░   0.014 s  (14 ms)
ThunderNet   ████████████████████████   0.250 s  (250 ms)
```

ThunderNet is slower here on purpose: it sends unreliable messages one at a
time so Roblox does not silently drop oversized bundles. 250 ms is about 15
frames for 1,000 messages (≈4,000/second). Normal cosmetic updates are usually a
few per second per player, far below that.

**Data removed by compression** (not a speed chart)

```text
300 messages × 2 KB (600 KB of very repetitive test data)
Compression removed   ████████████████████████   592 KB
```

Compression saves bandwidth but costs CPU. Use it only for large, repetitive
payloads and measure the trade in your own game. The test data was extremely
compressible, so do not expect this ratio in normal gameplay.

**Time for one internal operation** (lower is better)

```text
Signal notification      ▏                        0.14 µs
Batcher push + flush     █                        0.26 µs
Security payload check   ███                      0.99 µs
Middleware (5 checks)    ███                      1.08 µs
Serializer decode        ████████                 3.12 µs
Serializer encode        ███████████              4.22 µs
```

Even the most expensive building block is a few microseconds. The messaging
layer is not what will make your game feel slow.

**How to feel these times**

- One frame at 60 FPS is **16.7 ms**. Several thousand normal updates fit inside
  a fraction of a frame.
- 2,000 updates in 6–9 ms is quicker than a camera flash.
- A quarter of a second for the 1,000-message unreliable burst is about 15
  frames — only relevant if you are deliberately sending huge bursts.
- One request round-trip is roughly three frames of waiting in Play Solo.

### Faster or slower? One line each

- **2,000 normal updates:** 0.006–0.009 s — faster than a single 60 FPS frame (0.0167 s).
- **Per message:** ThunderNet is about **5× slower** than bare native work here
  (4.55 µs vs 0.85 µs) because it validates and organizes; still ~220,000/s.
- **300 RPCs in a burst:** 0.052 s vs roughly **15 s** one at a time — about
  **280× less waiting** (the one-at-a-time figure is an estimate dominated by
  waiting for game ticks, not CPU).
- **1,000 unreliable updates:** 0.250 s vs 0.014 s native — about **18× slower**
  in a burst, the price of avoiding oversized-packet drops. Normal cosmetic
  update rates are far below this.
- **Compression:** removes ~592 KB from the test payloads but adds CPU time; it
  is a bandwidth trade, not a speed win.

### Win / loss summary

There is no single winner. Native raw remotes win on per-message CPU and
simplicity; ThunderNet wins on volume, safety, request/response and built-in
plumbing. The same number can be a win on one scoreboard and a loss on another.

| What is being compared | Native raw Roblox remotes | ThunderNet | Who wins, and why |
| --- | --- | --- | --- |
| CPU cost for one message | ~0.85 µs | ~4.55 µs | **Native** — raw speed, no checks or batching |
| 2,000 updates, server → player | ~17 ms (this sample) | ~6 ms (this sample) | **ThunderNet on this sample** — fewer calls via batching; burst timing is noisy |
| 2,000 updates, player → server | ~1.7 ms | ~9.1 ms | **Native** — raw speed |
| 1,000 unreliable updates | ~14 ms | ~250 ms | **Native** on pure speed; **ThunderNet** if silent packet drops matter |
| Request/response | Bare `RemoteFunction`/custom code; you build timeouts, retries, dedupe | Built-in timeouts, retries, backoff, dedupe, cancellation | **ThunderNet** on features; not a like-for-like speed comparison |
| Sending many messages | One network call per message | Batches many messages per call | **ThunderNet** on fewer calls; real-network gain untested |
| Compression | None built in | ~592 KB saved in the test, at CPU cost | **Depends** — ThunderNet for bandwidth, native for CPU |
| Security input checks | None by default | Rate limits, size/depth checks, schema validation | **ThunderNet** on safety, not raw speed |
| Simplicity | One object, few decisions | More features, settings and concepts to learn | **Native** — less complexity |
| Real internet speed | Same Roblox internet | Same Roblox internet | **Tie** — not measured with real players |

### Is ThunderNet more complex?

Yes. It has many more moving parts than a plain `RemoteEvent`, and that is a
real cost: more to learn, more to configure, and a few extra microseconds of CPU
per message.

The trade is deliberate:

- **Choose native raw remotes** for tiny prototypes, a handful of messages, or
  when simplicity matters more than safety and structure.
- **Choose ThunderNet** when several systems and players exchange many messages,
  when you need request/response, validation, rate limits, statistics or cleanup,
  and when you do not want to rebuild that plumbing yourself.
- The complexity lives mostly **inside the library**. Your handlers still look
  like ordinary event callbacks; you pay for the features with CPU and learning
  time, not with complicated gameplay code.

### Which should you use? A simple decision tree

```text
Start
  |
  |-- Is this a quick prototype, jam, or one tiny feature?
  |     |
  |     |-- Yes --> Does the player affect anything valuable (currency,
  |     |            inventory, purchases, combat results, ownership)?
  |     |            |
  |     |            |-- No  --> Native RemoteEvent is probably enough.
  |     |            |-- Yes --> ThunderNet. Losing items "only in the
  |     |                         prototype" is still losing items.
  |     |
  |     |-- No (a real game with several systems)
  |           |
  |           |-- Need request/response with answers, retries or timeouts?
  |           |         |-- Yes --> ThunderNet
  |           |         |-- No  --> keep asking
  |           |
  |           |-- Many messages per second, or many players?
  |           |         |-- Yes --> ThunderNet (batching)
  |           |         |-- No  --> keep asking
  |           |
  |           |-- Need validation, rate limits, permissions or stats?
  |           |         |-- Yes --> ThunderNet
  |           |         |-- No  --> keep asking
  |           |
  |           |-- Only a few simple, trusted messages?
  |           |         |-- Yes --> Native is fine
  |           |         |-- No  --> ThunderNet
  |
  |-- Still unsure?
        Start with native for one truly simple message if you like,
        but move to ThunderNet as soon as any box below applies.
```

### Quick checklist

**Choose ThunderNet if any of these are true:**

- [ ] The server decides anything valuable: damage, currency, inventory, prices, ownership, cooldowns.
- [ ] Players trigger actions that need validation or permission checks.
- [ ] You need questions with answers (request/response), retries, timeouts or duplicate protection.
- [ ] The game sends many updates per second, or many players send updates.
- [ ] Several gameplay systems need to share networking.
- [ ] You want built-in rate limiting, payload limits and abuse protection.
- [ ] You need reliable and unreliable lanes, priorities, statistics or cleanup.
- [ ] This is a long-lived project where you would otherwise rebuild plumbing.

**Native raw remotes are reasonable only if all of these are true:**

- [ ] The feature is tiny: one or two simple messages.
- [ ] Nothing valuable or security-sensitive depends on the data.
- [ ] You do not need request/response, batching, retries or rate limiting.
- [ ] You are prototyping and accept writing the safety layer later.
- [ ] Simplicity and minimal code matter more than infrastructure.

**Rule of thumb:** if you tick even **one** ThunderNet box, use ThunderNet.
If you tick every native box, native is a perfectly good choice.

You can mix both in one game, but keep one source of truth per piece of data.
For example, use ThunderNet for gameplay actions and a plain remote for a
trusted server-to-UI notification — but do not send the same state through both.

### Everyday game updates (events)

We sent 2,000 small updates back-to-back and timed how long it took the other
side to receive them.

| Direction | ThunderNet result | In plain terms |
| --- | --- | --- |
| Server → player | 2,000 messages in about 6 ms | ~329,000 messages/second |
| Player → server | 2,000 messages in about 9 ms | ~220,000 messages/second |

A busy Roblox game might send a few hundred messages per second in total. The
test pushed thousands in a few milliseconds. **You are unlikely to hit these
limits with normal gameplay.**

> The bare "native" Roblox remote in the same test showed ~119,000/second
> server→player and ~1,170,000/second player→server. Native skips all checks,
> packing and receipts. It is expected to look faster. ThunderNet is not trying
> to beat Roblox's raw transport; it is adding safety and organization on top.

### Requests that need an answer (RPC)

Some messages are questions: "Did my purchase succeed?" The client must wait for
the server's answer.

| Style | Result | What it means |
| --- | --- | --- |
| One at a time | 50 questions in ~2.5 seconds | About 50 ms per question, because each waits its turn |
| Sent as a burst | 300 questions in ~52 ms | ~5,700 questions/second |

The one-at-a-time number is mostly **waiting**, not slowness: each round-trip
waits for the game's next network tick. If you fire many requests together, the
burst number shows the system keeps up easily.

### Big repetitive data (compression)

We sent 300 messages that each contained 2 KB of very repetitive data, with
compression turned on.

- It saved about **592,000 bytes** of data overall — roughly 1.97 KB per message.
- It was slower than sending uncompressed data because compressing costs CPU.

**Plain advice:** compression is optional. Use it when bandwidth matters and
your data is large and repetitive. Do not turn it on just because it sounds
impressive; measure first.

### Quick, throwaway updates (unreliable messages)

Some updates are cosmetic and can be missed: trail effects, tiny visual
positions, transient sparks.

- We sent 1,000 of these from server to player; **all 1,000 arrived** in the local test.
- It took about 250 ms in a burst because ThunderNet deliberately sends them
  **one at a time by default**.
- The bare Roblox unreliable remote sent 1,000 in about 14 ms, but with **zero
  safety checks**.

Why one at a time? Roblox limits how big an unreliable call can be. Sending
several at once risks the engine silently throwing them away. ThunderNet now
chooses safety over burst speed for this lane. For normal cosmetic updates
(a handful per second per player), this is a non-issue.

### The internal building blocks

These are pieces used by the system above. They are listed so engineers can
compare versions, not because a designer needs to memorize them.

| Building block | Speed | What it does |
| --- | ---: | --- |
| Signal | ~6.9 million/s | Delivers internal notifications |
| Middleware chain | ~924,000/s | Runs up to 5 security/custom checks |
| Batcher | ~3.8 million/s | Sorts messages into batches |
| Serializer (encode/decode) | ~237k / 320k per second | Packs/unpacks structured data |
| Payload security check | ~1.01 million/s | Rejects oversized or unsafe data |
| Simple compression | ~6,250/s compress, ~44,000/s decompress | Shrinks repetitive data |

Even the "slow" pieces are measured in tens of thousands per second, far above
normal game traffic.

---

## Why is ThunderNet slower than native in some tests?

Native Roblox remotes are like handing someone a letter directly. ThunderNet is
like a courier that:

- checks the package is allowed and the right size,
- groups many letters into one delivery,
- keeps a receipt for questions that need answers,
- enforces spam limits.

That service costs a little CPU. The benchmark's job is to show the cost is
small compared with what a game actually sends. It is **not** fair to read the
tables as "ThunderNet is X times slower than Roblox"; they measure different
amounts of work.

---

## The bug that real Roblox testing caught

The simulation looked fine, but the real Roblox Studio run exposed a serious
issue:

- ThunderNet was grouping **64** unreliable messages into one call.
- Roblox has a roughly **900-byte cap** on unreliable calls.
- The engine **silently dropped** every oversized bundle, so zero messages arrived.
- Fix: unreliable messages now go **one per call by default**. After the fix,
  1,000 out of 1,000 arrived in both directions.
- We added two automated tests so this cannot quietly come back.

This is exactly why testing inside the real engine matters. A simulation can be
too forgiving.

---

## What these tests cannot tell you

- **Real internet performance.** Studio Play Solo is a local server. Real ping,
  packet loss and bandwidth need live players and telemetry.
- **Your game's total performance.** Game logic, physics, rendering and player
  devices matter more than the messaging layer in most projects.
- **Whether gameplay "feels" fast.** That is a design and live-testing question.
- **Cheating protection in your game rules.** ThunderNet validates messages and
  limits abuse; your server code must still decide what is actually allowed
  (damage, prices, ownership, positions).

---

## What we would tell a game team

- **Normal events:** use them freely; the system handles far more than a typical
  game sends.
- **Requests:** fine for gameplay actions; if you need many at once, send them
  concurrently rather than one-at-a-time.
- **Compression:** leave it off unless you have large, repetitive payloads and
  have measured the benefit.
- **Unreliable updates:** use them for cosmetics; leave the safe default
  (one message per call) alone unless you know exactly why you need otherwise.
- **Security:** validation and rate limits are on the server; still write
  server-authoritative game logic.
- **Confidence:** 160 automated tests pass, strict type checking is clean, and a
  real Studio Play Solo run completed successfully after the unreliable fix.

---

## Mini glossary

| Word | Plain meaning |
| --- | --- |
| Message | One piece of game data sent over the network |
| Remote event | Roblox's basic tool for sending messages |
| Batch | Several messages packed into one network call |
| RPC | A message that asks for an answer |
| Reliable | Delivery is guaranteed and ordered |
| Unreliable | Faster/cheaper, but messages may be dropped |
| Server | The trusted computer that runs the game |
| Client | The player's device |
| ms / µs | Milliseconds / microseconds; smaller is faster |
| Throughput | How many messages per second |
| Latency | How long one message takes to arrive |

---

## Want the engineering details?

- [Technical benchmark methodology and tables](docs/BENCHMARKS.md)
- [How the system works](docs/ARCHITECTURE.md)
- [Security model](docs/SECURITY.md)
- [Main README](README.md)
