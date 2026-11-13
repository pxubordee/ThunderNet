# Build your first ThunderNet For Roblox feature

ThunderNet For Roblox (full name: **ThunderNetworking**) is a typed,
server-authoritative networking framework. This tutorial assumes you know how to
make a Roblox `Script`/`LocalScript` and run the game in Studio. You do not need
to know networking frameworks.

You will build:

1. A combat event the client can trigger.
2. Server-side validation that rejects bad data.
3. A broadcast to every player.
4. A purchase request with an answer.
5. Middleware, unreliable updates, and debugging hooks.

The complete API is in [API.md](API.md).

---

## Step 0 — Install ThunderNet

ThunderNet For Roblox is distributed as a single `.rbxm` on GitHub Releases.

1. Open the [latest GitHub Release](https://github.com/pxubordee/ThunderNet/releases/latest).
2. Download `ThunderNet-<version>.rbxm` and its `.sha256` checksum.
3. Verify the checksum (Linux: `sha256sum -c file.sha256`; macOS:
   `shasum -a 256 -c file.sha256`).
4. In Studio, open **Explorer**, select **ReplicatedStorage**, and drag the file
   in.
5. Confirm a `ModuleScript` named `ThunderNet` exists with `Core`, `Features`,
   `Security`, `Transport`, `Utilities`, and `Types` folders, plus a `LICENSE`
   StringValue with the MIT notice.

This is the only supported installation method. The source repository is for
developing the framework itself.

---

## Step 1 — Create the server session

Create a `Script` in **ServerScriptService** named `CombatServer`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ThunderNet = require(ReplicatedStorage:WaitForChild("ThunderNet"))

local Net = ThunderNet.Server({ Name = "ThunderNet" })
print("ThunderNet server ready")
```

Press **Play**. You should see `ThunderNet server ready` in the Output window and
a folder named `ThunderNet` in ReplicatedStorage, containing `Reliable`,
`Unreliable`, and `Configuration`.

---

## Step 2 — Add an event and validate its data

Replace the script with:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ThunderNet = require(ReplicatedStorage:WaitForChild("ThunderNet"))

local Net = ThunderNet.Server({ Name = "ThunderNet" })

type CombatData = {
    Damage: number,
    TargetName: string,
}

local Combat = ThunderNet.Event<CombatData>(Net, "Combat", {
    Priority = "High",
    -- This runs on the server for every incoming payload.
    Schema = ThunderNet.Validator.Table({
        Fields = {
            Damage = ThunderNet.Validator.Number({ Min = 0, Max = 100 }),
            TargetName = ThunderNet.Validator.String({ MaxLength = 32 }),
        },
    }),
})

Combat.OnServerEvent:Connect(function(player, data)
    -- Never trust client numbers for real gameplay.
    local damage = math.clamp(data.Damage, 0, 10)

    print(("%s hit %s for %d"):format(player.Name, data.TargetName, damage))

    -- Broadcast the authoritative result to everyone.
    Combat:FireAll({
        Damage = damage,
        TargetName = data.TargetName,
    })
end)
```

What each part does:

| Part | Meaning |
| --- | --- |
| `ThunderNet.Event<CombatData>` | Creates a typed event named `Combat`. |
| `Priority = "High"` | Sends it ahead of normal traffic in a frame. |
| `Schema` | Runtime validation on the server; types alone do not validate clients. |
| `OnServerEvent` | Runs when a client fires this event. |
| `FireAll` | Sends the result to every player. |

---

## Step 3 — Fire the event from the client

Create a `LocalScript` in **StarterPlayer → StarterPlayerScripts** named
`CombatClient`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ThunderNet = require(ReplicatedStorage:WaitForChild("ThunderNet"))

local Net = ThunderNet.Client({ Name = "ThunderNet" })

type CombatData = {
    Damage: number,
    TargetName: string,
}

-- The client handle mirrors the server event name.
local Combat = assert(Net:GetEvent("Combat")) :: ThunderNet.TypedEvent<CombatData>

Combat.OnClientEvent:Connect(function(data)
    print("Server says:", data.TargetName, "took", data.Damage, "damage")
end)

task.wait(2)

-- Try a valid hit.
Combat:FireServer({ Damage = 5, TargetName = "Dummy" })
```

Press **Play** and check both outputs:

- Server: `YourName hit Dummy for 5`
- Client: `Server says: Dummy took 5 damage`

> The client sends a **request**, not the truth. The server decides the real
> damage before broadcasting it.

---

## Step 4 — Watch invalid data get rejected

On the server, add a drop hook before the `OnServerEvent` connection:

```lua
Net.OnDrop:Connect(function(info)
    warn("Dropped:", info.Code, info.Channel)
end)
```

On the client, send bad data once:

```lua
Combat:FireServer({ Damage = 1000, TargetName = "Dummy" })
```

The server prints a `Dropped: INVALID_PAYLOAD Combat` warning and the handler
does not run. This is runtime validation; a Luau type annotation would not stop
a modified client.

---

## Step 5 — Add a request/response (RPC)

A request is a message that waits for an answer.

Add to the **server** script:

```lua
Net:OnRequest("Purchase", function(player, request)
    -- Check server-side state before granting anything.
    local price = 100
    local balance = 500 -- replace with your real data

    if balance < price then
        return { Success = false, Reason = "NOT_ENOUGH_COINS" }
    end

    return {
        Success = true,
        ItemId = request.ItemId,
        RemainingBalance = balance - price,
    }
end)
```

Add to the **client** script:

```lua
type PurchaseRequest = { ItemId: number }
type PurchaseResult = {
    Success: boolean,
    ItemId: number?,
    RemainingBalance: number?,
    Reason: string?,
}

local purchase: ThunderNet.PromiseOf<PurchaseResult> =
    Net:InvokeServer("Purchase", { ItemId = 7 } :: PurchaseRequest, {
        Timeout = 3,
        MaxAttempts = 2,
    })

purchase:AndThen(function(result)
    if result.Success then
        print("Purchased item", result.ItemId)
    else
        warn("Purchase failed:", result.Reason)
    end
end)

purchase:Catch(function(err)
    warn("Purchase error:", err.Code, err.Message)
end)
```

If you prefer synchronous-looking code, use `:Await()` inside a script thread:

```lua
local result = Net:InvokeServer("Purchase", { ItemId = 7 }):Await()
print(result.Success)
```

Use `Idempotent = false` when retrying a side effect must be avoided:

```lua
Net:InvokeServer("Purchase", data, { Idempotent = false })
```

---

## Step 6 — Add middleware

Middleware inspects or modifies every inbound message. Add to the **server**
script:

```lua
Net:Use(function(context, next)
    print("Incoming:", context.Channel, "from", tostring(context.Player))
    return next(context)
end)
```

To reject a message, return `false`:

```lua
Net:Use(function(context, next)
    if context.Data.Blocked then
        return false, "BLOCKED"
    end
    return next(context)
end)
```

Per-event middleware works the same way:

```lua
local Combat = ThunderNet.Event<CombatData>(Net, "Combat", {
    Middleware = {
        function(context, next)
            context.Data.Checked = true
            return next(context)
        end,
    },
})
```

Outbound middleware runs before sending an event:

```lua
local token = Net:UseOutbound(function(context, next)
    print("Sending:", context.Channel, "to", tostring(context.Player))
    return next(context)
end)

-- Later:
Net:UnuseOutbound(token)
```

Middleware must call `next(context)` exactly once, or return `false, reason`.

---

## Step 7 — Add a frequent cosmetic update

Unreliable updates are for things that can be missed: trails, sparks, transient
visual positions.

Server:

```lua
type PositionData = { Position: Vector3 }

local Movement = ThunderNet.Event<PositionData>(Net, "Movement", {
    Unreliable = true,
    Priority = "Low",
})

Movement.OnServerEvent:Connect(function(_player, _data)
    -- Do not make authoritative gameplay depend on this lane.
end)
```

Client:

```lua
local Movement = assert(Net:GetEvent("Movement", { Unreliable = true })) :: ThunderNet.TypedEvent<PositionData>

Movement:FireServer({ Position = Vector3.new(10, 0, 10) })
```

ThunderNet sends unreliable messages one per call by default so Roblox's payload
cap does not silently drop oversized batches. Keep unreliable payloads small.

---

## Step 8 — Debug with stats and hooks

Server or client:

```lua
print(Net:GetStats())
```

Useful fields: `MessagesSent`, `MessagesReceived`, `BatchesSent`,
`AverageBatchSize`, `QueueDepth`, `DroppedPackets`, `PayloadRejected`,
`RateLimited`, `QueueOverflow`, `OutboundRejected`, `RequestsPending`,
`RequestsTimedOut`, `Retries`.

Hooks:

```lua
Net.OnError:Connect(function(info)
    warn("ThunderNet error:", info.Code, info.Message)
end)

Net.OnDrop:Connect(function(info)
    warn("Dropped:", info.Code, info.Channel)
end)

Net.OnRateLimited:Connect(function(info)
    warn("Rate limited:", info.Player, info.RetryAfter)
end)
```

Remember that bytes and timings are estimates, not real network bandwidth or
ping.

---

## Step 9 — Security checklist

- Re-check damage, currency, inventory, prices, ownership and cooldowns on the
  server; framework validation checks shape, not game meaning.
- Never send purchases, inventory or critical state over the unreliable lane.
- Use schemas and custom validation for every client-triggered event.
- Set `Permission` or authorization middleware for sensitive actions.
- Keep request handlers fast; do not yield indefinitely.
- Keep `DedupeTtl` longer than your worst retry window.
- Watch `DroppedPackets`, `PayloadRejected`, `RateLimited` and `QueueOverflow`
  while developing.

---

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `ThunderNet remotes were not found` | The client started before the server session, or the names differ. |
| `A ThunderNet instance named ... already exists` | Another session with the same `Name` is alive. Destroy it or use a unique name. |
| Nothing arrives | Check the client `GetEvent` name, both sides' configuration, and `GetStats()`. |
| `INVALID_PAYLOAD` | Wrong shape/type, too large, too deep, or schema mismatch. |
| `NO_HANDLER` | Missing `Net:OnRequest` on the receiving side. |
| `TIMEOUT` | Handler did not return; check request options and retries. |
| Unreliable messages missing | Payload too large for the unreliable cap or receiver config differs. |
| Middleware rejects everything | A middleware is not calling `next` or is returning `false`. |
| Studio tests fail | The in-Studio runner only runs synchronous specs; use `./scripts/test.sh`. |

---

## Next steps

- [API reference](API.md)
- [Architecture](ARCHITECTURE.md)
- [Security model](SECURITY.md)
- [Benchmarks in plain English](../BENCHMARKS-SIMPLE.md)
- [Roadmap](ROADMAP.md)
