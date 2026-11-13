# ThunderNet API reference

This is the complete public API. If you are new, start with the
[step-by-step tutorial](TUTORIAL.md). For configuration and benchmarks, see the
[README](../README.md) and [BENCHMARKS.md](BENCHMARKS.md).

## Entry points

```lua
local ThunderNet = require(game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet"))
```

| Function | Result |
| --- | --- |
| `ThunderNet.Server(config?)` | Creates a server session. Creates the remotes folder. |
| `ThunderNet.Client(config?)` | Creates a client session. Waits for the server remotes. |
| `ThunderNet.Init(config?)` | Calls `Server` on the server and `Client` on the client. |
| `ThunderNet.Event<T>(Net, name, options?)` | Typed helper that creates an event and returns `TypedEvent<T>`. |

Exposed utilities: `ThunderNet.Signal`, `ThunderNet.Promise`,
`ThunderNet.Janitor`, `ThunderNet.Validator`, `ThunderNet.Permissions`,
`ThunderNet.Types`, and `ThunderNet.Priority` (priority name constants).

## Network methods

`Net` is the object returned by `Server`, `Client`, or `Init`.

| Method | Description |
| --- | --- |
| `Net:IsServer()` / `Net:IsClient()` | Returns the session side. |
| `Net:GetName()` | Returns the remotes folder name. |
| `Net:CreateEvent<T>(name, options?)` | Creates (or returns) an event. Server normally creates them. |
| `Net:GetEvent<T>(name, options?)` | Returns an event handle. On a client, creates the handle lazily if needed; on a server, returns `nil` if it was never created. |
| `Net:CreateChannel(name, defaults?)` | Creates a channel that groups events and shares default options. |
| `Net:Use(middleware)` | Adds inbound middleware. Returns a removal token. |
| `Net:Unuse(token)` | Removes inbound middleware. |
| `Net:UseOutbound(middleware)` | Adds outbound event middleware. Returns a removal token. |
| `Net:UnuseOutbound(token)` | Removes outbound event middleware. |
| `Net:OnRequest<TRequest, TResult>(name, handler)` | Registers an RPC handler: `function(player, data) return result end`. On a client the player is `nil`. |
| `Net:InvokeServer<TRequest, TResult>(name, data, options?)` | Client → server request. Returns a promise. |
| `Net:InvokeClient<TRequest, TResult>(player, name, data, options?)` | Server → client request. Returns a promise. |
| `Net:After(seconds, callback)` | Runs a lifecycle-managed timer; cancelled by `Destroy`. |
| `Net:GetStats()` | Returns a statistics snapshot (see below). |
| `Net:Destroy()` | Disconnects remotes, heartbeats, queues, requests and caches; removes the server remotes folder. |

Network signals (public fields):

| Signal | Payload |
| --- | --- |
| `Net.OnError` | `{ Code, Message, Channel?, Player?, RequestId?, Error? }` |
| `Net.OnDrop` | `{ Code, Message, Channel?, Player?, RequestId?, Destination?, RetryAfter? }` |
| `Net.OnRateLimited` | `{ Code = "RATE_LIMITED", Player, Channel?, RetryAfter? }` |

An error thrown by a hook is warned and isolated; it does not break dispatch.

## Event object

Created by `CreateEvent` / `GetEvent` / `Channel:CreateEvent`.

Fields:

| Field | Description |
| --- | --- |
| `Name` | Wire name, including channel prefix if created through a channel. |
| `OnServerEvent` | Signal fired on the server as `(player, data)`. |
| `OnClientEvent` | Signal fired on the client as `(data)`. |

Methods:

| Method | Description |
| --- | --- |
| `event:FireServer(data, priority?)` | Client → server event. |
| `event:FireClient(player, data, priority?)` | Server → one player. |
| `event:FireAll(data, priority?)` | Server → every player (per-player batches). |
| `event:FireExcept(excluded, data, priority?)` | Server → every player except one. |
| `event:FireMany(players, data, priority?)` | Server → a provided list of players. |
| `event:SetPriority(priority)` / `event:GetPriority()` | Default priority for this event. |
| `event:IsUnreliable()` | Whether it uses the unreliable lane. |
| `event:SetPermission(fn)` / `event:GetPermission()` | Per-event server authorization `(player, data) -> boolean, reason?`. |
| `event:GetOptions()` | The normalized event options table. |
| `event:Use(middleware)` / `event:Unuse(token)` | Per-event inbound middleware. |
| `event:GetMiddlewareCount()` | Number of per-event middleware entries. |

Priorities: `"Critical"`, `"High"`, `"Normal"`, `"Low"`, `"Background"`.

## Event options

| Option | Type | Description |
| --- | --- | --- |
| `Unreliable` | `boolean?` | Use `UnreliableRemoteEvent`. Set the same option on the client handle. |
| `Priority` | `string?` | Default priority. |
| `Schema` | schema? | Runtime payload schema, checked server-side. |
| `Validate` | `(data) -> boolean, reason?` | Custom runtime validation. |
| `Permission` | `(player, data) -> boolean, reason?` | Server authorization. |
| `RateLimit` | `{ Rate, Burst }?` | Extra per-event token bucket. |
| `Middleware` | `{ function }?` | Initial per-event inbound middleware. |

## Request options

`InvokeServer` / `InvokeClient` accept a third/fourth options argument:

| Option | Type | Description |
| --- | --- | --- |
| `Timeout` | `number?` | Per-attempt timeout in seconds. |
| `MaxAttempts` | `number?` | Attempt budget for this request. |
| `Idempotent` | `boolean?` | `false` forces one attempt. |

Backoff base/max/jitter remain session-configured. The receiver caches responses
for `DedupeTtl` so retries do not re-execute a handler whose response was lost.

## Promise

`ThunderNet.Promise`:

| API | Description |
| --- | --- |
| `Promise.new()` | Pending promise. |
| `Promise.resolve(value)` / `Promise.reject(reason)` | Settled promise. |
| `Promise.all(items)` | Resolves all promises/values in order, rejects on the first rejection. |
| `promise:Resolve(value)` / `promise:Reject(reason)` | Settle a pending promise. |
| `promise:AndThen(fn)` / `promise:Catch(fn)` / `promise:Finally(fn)` | Chain results and errors. |
| `promise:Await(timeout?)` | Yields the calling thread until settled and returns/throws. |
| `promise:Cancel()` | Cancels a pending promise (sends an RPC cancel when used by RPC). |
| `promise:OnCancel(fn)` | Runs a hook when cancelled. |
| `promise:GetStatus()` | `"Pending"`, `"Resolved"`, `"Rejected"`, or `"Cancelled"`. |

## Channels

| API | Description |
| --- | --- |
| `Net:CreateChannel(name, defaults?)` | Returns a channel object. |
| `channel:CreateEvent<T>(localName, options?)` | Creates `"Channel/Event"` with defaults merged. |
| `channel:GetEvent<T>(localName, options?)` | Gets the client handle for `"Channel/Event"`. |
| `channel:GetName()` | Channel name. |

## Validator

Runtime schemas (`ThunderNet.Validator`):

| Constructor | Description |
| --- | --- |
| `V.Any`, `V.Boolean`, `V.Vector3` | Primitive checks. |
| `V.Number({ Min, Max, Integer })` | Number constraints. |
| `V.String({ MinLength, MaxLength })` | String constraints. |
| `V.Instance(className?)` | Instance and optional `IsA` check. |
| `V.Table({ Fields, AllowUnknown })` | Field-by-field table validation. |
| `V.Array(element, { MinLength, MaxLength })` | Homogeneous arrays. |
| `V.Optional(schema)` | Allows `nil`. |
| `V.Literal(value)` | Exact value. |
| `V.OneOf({ schemas })` | First matching schema. |
| `V.Map(keySchema, valueSchema)` | Arbitrary keys and values. |
| `V.Validate(value, schema, path?)` | Returns `boolean, errorMessage?`. |
| `V.CheckPayload(value, { MaxBytes, MaxDepth })` | Structural limit walk used by the network. |

Compile-time types do not replace these runtime checks.

## Permissions

| Helper | Description |
| --- | --- |
| `Permissions.AllowAll` / `Permissions.DenyAll` | Always allow/deny. |
| `Permissions.UserIds({ ids })` | Allow listed user ids. |
| `Permissions.GroupRank(groupId, minimumRank)` | Requires a Roblox group rank. |
| `Permissions.HasAttribute(name, expected?)` | Requires a player attribute (truthy by default). |
| `Permissions.Custom(fn)` | Wrap your own check. |
| `Permissions.Compose(a, b, ...)` | All checks must pass; first failure wins. |

## Utilities

### Signal

`Signal.new()`, `:Connect(fn) -> Connection`, `:Fire(...)`,
`:DisconnectAll()`, `:GetConnectionCount()`, `:Destroy()`;
connection `:Disconnect()`.

### Janitor

`Janitor.new()`, `:Add(item)`, `:Remove(item)`, `:GetCount()`, `:Cleanup()`,
`:Destroy()`. Cleans functions, connections, Instances, nested Janitors and
objects with `Destroy`, in reverse insertion order.

## Statistics

`Net:GetStats()` returns:

`PacketsSent`, `PacketsReceived`, `MessagesSent`, `MessagesReceived`,
`BatchesSent`, `AverageBatchSize`, `QueueOverflow`, `OutboundRejected`,
`BytesSentEstimate`, `CompressionSavingsBytes`, `QueueDepth`, `RequestsSent`,
`RequestsPending`, `RequestsTimedOut`, `Retries`, `MalformedPackets`,
`DroppedPackets`, `RateLimited`, `MiddlewareRejected`, `PermissionsDenied`,
`PayloadRejected`, `Dispatches`, `DispatchTimeMs`, `AverageDispatchTimeMs`,
`MessagesByPriority`.

Byte counts are estimates; ping and real bandwidth are not reported.

## Drop and error codes

| Code | Meaning |
| --- | --- |
| `MALFORMED_PACKET` | Structurally invalid packet. |
| `UNKNOWN_EVENT` | Server has no such event. |
| `INVALID_LANE` | Event/RPC used the wrong reliable/unreliable lane. |
| `INVALID_PAYLOAD` | Decode, size, depth, schema or custom validation failed. |
| `PERMISSION_DENIED` | Event permission denied. |
| `MIDDLEWARE_REJECTED` | Global, per-event or request middleware rejected. |
| `OUTBOUND_REJECTED` | Outbound middleware rejected an event send. |
| `QUEUE_OVERFLOW` | Queue depth cap reached; message dropped. |
| `NO_HANDLER` | Request had no registered handler. |
| `HANDLER_ERROR` | Request handler threw. |
| `UNKNOWN_RESPONSE` | Response id did not match a pending request. |
| `RATE_LIMITED` | Rate limit exceeded. |
| `TIMEOUT`, `CANCELLED`, `REJECTED`, `PLAYER_LEFT`, `DESTROYED` | RPC outcomes. |

## Type notes

Luau does not allow explicit type arguments on method calls. Use the typed
helper or annotate the receiver:

```lua
local Combat = ThunderNet.Event<CombatData>(Net, "Combat", options)
-- or:
local Combat = Net:CreateEvent("Combat", options) :: ThunderNet.TypedEvent<CombatData>

local purchase: ThunderNet.PromiseOf<PurchaseResult> =
    Net:InvokeServer("Purchase", { ItemId = 7 } :: PurchaseRequest)
```

See the [tutorial](TUTORIAL.md) for a guided build.
