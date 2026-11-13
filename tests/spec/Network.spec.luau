--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Runtime = require(script.Parent.Parent.Support.Runtime)
local ThunderNet = require(ThunderNetFolder)
local Protocol = require(ThunderNetFolder.Core.Protocol)

local describe, it = TestHarness.describe, TestHarness.it
local replicatedStorage = game:GetService("ReplicatedStorage")

local nameCounter = 0

local function mergeConfig(base, overrides)
	if overrides then
		for key, value in pairs(overrides) do
			base[key] = value
		end
	end
	return base
end

local function withNetworks(body)
	nameCounter += 1
	local networkName = "TNet" .. nameCounter
	local created = {}
	local players = {}
	local env = { name = networkName }

	function env.server(overrides)
		local network = ThunderNet.Server(mergeConfig({ Name = networkName }, overrides))
		table.insert(created, network)
		return network
	end

	function env.client(player, overrides)
		Runtime.setClient(player)
		local ok, network = pcall(ThunderNet.Client, mergeConfig({ Name = networkName }, overrides))
		Runtime.clearClient()
		if not ok then
			error(network, 0)
		end
		table.insert(created, network)
		return network
	end

	function env.player(name)
		local player = Runtime.createPlayer(name)
		table.insert(players, player)
		return player
	end

	function env.remoteView(player, lane)
		local folder = replicatedStorage:WaitForChild(networkName)
		return Runtime.withClient(player, function()
			return folder:WaitForChild(lane or "Reliable")
		end)
	end

	local ok, err = pcall(function()
		body(env)
	end)

	for _, player in ipairs(players) do
		if player.Parent ~= nil then
			pcall(Runtime.removePlayer, player)
		end
	end
	for index = #created, 1, -1 do
		pcall(created[index].Destroy, created[index])
	end

	if not ok then
		error(err, 0)
	end
end

describe("Network initialization", function()
	it("initializes a server with remotes and event handles", function()
		withNetworks(function(env)
			local server = env.server()
			Expect(server:IsServer()):toBeTruthy()
			local folder = replicatedStorage:FindFirstChild(env.name)
			Expect(folder):toBeTruthy()
			Expect(folder.Reliable.ClassName):toBe("RemoteEvent")
			Expect(folder.Unreliable.ClassName):toBe("UnreliableRemoteEvent")

			local combat = server:CreateEvent("Combat")
			Expect(combat.Name):toBe("Combat")
			Expect(server:CreateEvent("Combat")):toBe(combat)
			Expect(server:GetEvent("Combat")):toBe(combat)
			Expect(server:GetEvent("Missing")):toBeNil()
		end)
	end)

	it("initializes a client that shares server event names", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			env.server()
			local client = env.client(player)
			Expect(client:IsServer()):toBeFalsy()
			local combat = client:GetEvent("Combat")
			Expect(combat.Name):toBe("Combat")
			Expect(client:GetEvent("Combat")):toBe(combat)
		end)
	end)

	it("destroying removes remotes and is idempotent", function()
		withNetworks(function(env)
			local server = env.server()
			local combat = server:CreateEvent("Combat")
			server:Destroy()
			server:Destroy()
			Expect(replicatedStorage:FindFirstChild(env.name)):toBeNil()
			Expect(function()
				combat:FireAll({})
			end):toThrow()
		end)
	end)

	it("refuses to initialize a client before the server exists", function()
		local player = Runtime.createPlayer("EarlyBird")
		local ok = pcall(ThunderNet.Client, { Name = "MissingRemotesX" })
		Expect(ok):toBeFalsy()
		Runtime.removePlayer(player)
	end)
end)

describe("Network events", function()
	it("delivers server-to-client events with the payload", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			local clientCombat = client:GetEvent("Combat")
			local received = {}
			clientCombat.OnClientEvent:Connect(function(data)
				table.insert(received, data)
			end)
			combat:FireClient(player, { Damage = 7 })
			local delivered = Runtime.waitFor(function()
				return #received == 1
			end, 2)
			Expect(delivered):toBeTruthy()
			Expect(received[1].Damage):toBe(7)
		end)
	end)

	it("delivers client-to-server events with the sending player", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			server:CreateEvent("Combat")
			local clientCombat = client:GetEvent("Combat")
			local serverCombat = server:GetEvent("Combat")
			local received = {}
			serverCombat.OnServerEvent:Connect(function(sender, data)
				table.insert(received, { Sender = sender, Data = data })
			end)
			clientCombat:FireServer({ Damage = 3 })
			Expect(Runtime.waitFor(function()
				return #received == 1
			end, 2)):toBeTruthy()
			Expect(received[1].Sender):toBe(player)
			Expect(received[1].Data.Damage):toBe(3)
		end)
	end)

	it("isolates destinations", function()
		withNetworks(function(env)
			local alice = env.player("Alice")
			local bob = env.player("Bob")
			local server = env.server()
			local aliceClient = env.client(alice)
			local bobClient = env.client(bob)
			local combat = server:CreateEvent("Combat")
			local aliceReceived = 0
			local bobReceived = 0
			aliceClient:GetEvent("Combat").OnClientEvent:Connect(function()
				aliceReceived += 1
			end)
			bobClient:GetEvent("Combat").OnClientEvent:Connect(function()
				bobReceived += 1
			end)
			combat:FireClient(alice, { Target = alice })
			Runtime.advanceFrames(3)
			Expect(aliceReceived):toBe(1)
			Expect(bobReceived):toBe(0)
			combat:FireAll({ Broadcast = true })
			Runtime.advanceFrames(3)
			Expect(aliceReceived):toBe(2)
			Expect(bobReceived):toBe(1)
		end)
	end)

	it("preserves FIFO order and batches same-frame messages", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			local received = {}
			client:GetEvent("Combat").OnClientEvent:Connect(function(data)
				table.insert(received, data.Index)
			end)
			for index = 1, 5 do
				combat:FireClient(player, { Index = index })
			end
			Runtime.advanceFrames(3)
			Expect(received):toEqual({ 1, 2, 3, 4, 5 })
			local stats = server:GetStats()
			Expect(stats.MessagesSent):toBe(5)
			Expect(stats.BatchesSent):toBe(1)
			Expect(stats.QueueDepth):toBe(0)
		end)
	end)

	it("delivers unreliable events and rejects lane mismatches", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local fx = server:CreateEvent("FX", { Unreliable = true })
			Expect(fx:IsUnreliable()):toBeTruthy()
			local serverReceived = 0
			fx.OnServerEvent:Connect(function()
				serverReceived += 1
			end)
			local clientFx = client:GetEvent("FX", { Unreliable = true })
			clientFx:FireServer({ Trail = true })
			Runtime.advanceFrames(3)
			Expect(serverReceived):toBe(1)

			local combat = server:CreateEvent("Combat")
			local combatReceived = 0
			combat.OnServerEvent:Connect(function()
				combatReceived += 1
			end)
			local sneaky = client:GetEvent("Combat", { Unreliable = true })
			sneaky:FireServer({ Cheat = true })
			Runtime.advanceFrames(3)
			Expect(combatReceived):toBe(0)
			Expect(server:GetStats().DroppedPackets >= 1):toBeTruthy()
		end)
	end)

	it("drops events the server never registered", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local view = env.remoteView(player)
			view:FireServer(Protocol.Event("Ghost", { A = 1 }))
			Runtime.advanceFrames(3)
			Expect(server:GetStats().DroppedPackets >= 1):toBeTruthy()
		end)
	end)

	it("supports FireMany and FireExcept", function()
		withNetworks(function(env)
			local alice = env.player("Alice")
			local bob = env.player("Bob")
			local server = env.server()
			local aliceClient = env.client(alice)
			local bobClient = env.client(bob)
			local combat = server:CreateEvent("Combat")
			local aliceCount = 0
			local bobCount = 0
			aliceClient:GetEvent("Combat").OnClientEvent:Connect(function()
				aliceCount += 1
			end)
			bobClient:GetEvent("Combat").OnClientEvent:Connect(function()
				bobCount += 1
			end)
			combat:FireExcept(bob, { Tag = "except" })
			Runtime.advanceFrames(3)
			Expect(aliceCount):toBe(1)
			Expect(bobCount):toBe(0)
			combat:FireMany({ bob }, { Tag = "many" })
			Runtime.advanceFrames(3)
			Expect(aliceCount):toBe(1)
			Expect(bobCount):toBe(1)
		end)
	end)
end)

describe("Network request-response", function()
	it("handles client-to-server invocations", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local calls = 0
			server:OnRequest("Purchase", function(sender, data)
				calls += 1
				Expect(sender):toBe(player)
				return { Success = true, ItemId = data.ItemId }
			end)
			local promise = client:InvokeServer("Purchase", { ItemId = 42 })
			Expect(Runtime.waitFor(function()
				return promise:GetStatus() ~= "Pending"
			end, 2)):toBeTruthy()
			local result = promise:Await()
			Expect(result.Success):toBeTruthy()
			Expect(result.ItemId):toBe(42)
			Expect(calls):toBe(1)
			Expect(server:GetStats().RequestsPending):toBe(0)
		end)
	end)

	it("handles server-to-client invocations", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			client:OnRequest("RequestData", function(sender, data)
				Expect(sender):toBeNil()
				return { Echo = data.Question }
			end)
			local promise = server:InvokeClient(player, "RequestData", { Question = "ready" })
			Expect(Runtime.waitFor(function()
				return promise:GetStatus() ~= "Pending"
			end, 2)):toBeTruthy()
			Expect((promise:Await()).Echo):toBe("ready")
		end)
	end)

	it("propagates handler errors and missing handlers", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			server:OnRequest("Broken", function()
				error("handler exploded", 0)
			end)
			local broken = client:InvokeServer("Broken", {})
			Expect(Runtime.waitFor(function()
				return broken:GetStatus() ~= "Pending"
			end, 2)):toBeTruthy()
			local captured = nil
			broken:Catch(function(err)
				captured = err
			end)
			Expect(captured.Code):toBe("HANDLER_ERROR")

			local missing = client:InvokeServer("MissingHandler", {})
			Expect(Runtime.waitFor(function()
				return missing:GetStatus() ~= "Pending"
			end, 2)):toBeTruthy()
			local missingError = nil
			missing:Catch(function(err)
				missingError = err
			end)
			Expect(missingError.Code):toBe("NO_HANDLER")
		end)
	end)

	it("deduplicates retried requests so handlers run once", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local calls = 0
			server:OnRequest("Grant", function()
				calls += 1
				return { Granted = true }
			end)
			local view = env.remoteView(player)
			local envelope = Protocol.Request("Grant", "dup-1", { Amount = 5 })
			view:FireServer(envelope)
			view:FireServer(envelope)
			Runtime.advanceFrames(4)
			Expect(calls):toBe(1)
		end)
	end)

	it("cancels invocations before the response arrives", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local calls = 0
			server:OnRequest("Slowish", function()
				calls += 1
				return true
			end)
			local promise = client:InvokeServer("Slowish", {})
			promise:Cancel()
			Runtime.advanceFrames(4)
			Expect(promise:GetStatus()):toBe("Cancelled")
			Expect(calls <= 1):toBeTruthy()
		end)
	end)
end)

describe("Network security", function()
	it("rate limits inbound messages per player", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server({ RateLimit = { Rate = 1, Burst = 2 } })
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			local calls = 0
			combat.OnServerEvent:Connect(function()
				calls += 1
			end)
			local spam = client:GetEvent("Combat")
			for _ = 1, 5 do
				spam:FireServer({})
			end
			Runtime.advanceFrames(3)
			Expect(calls):toBe(2)
			local stats = server:GetStats()
			Expect(stats.RateLimited):toBe(3)
		end)
	end)

	it("honors per-event rate limits", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server({ RateLimit = { Rate = 100, Burst = 100 } })
			local client = env.client(player)
			local combat = server:CreateEvent("Combat", {
				RateLimit = { Rate = 1, Burst = 1 },
			})
			local calls = 0
			combat.OnServerEvent:Connect(function()
				calls += 1
			end)
			local spam = client:GetEvent("Combat")
			spam:FireServer({})
			spam:FireServer({})
			Runtime.advanceFrames(3)
			Expect(calls):toBe(1)
			Expect(server:GetStats().RateLimited >= 1):toBeTruthy()
		end)
	end)

	it("validates payloads with schemas and custom validators", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local combat = server:CreateEvent("Combat", {
				Schema = ThunderNet.Validator.Table({
					Fields = { Damage = ThunderNet.Validator.Number({ Min = 0, Max = 100 }) },
				}),
			})
			local received = {}
			combat.OnServerEvent:Connect(function(_, data)
				table.insert(received, data)
			end)
			local sender = client:GetEvent("Combat")
			sender:FireServer({ Damage = 500 })
			Runtime.advanceFrames(2)
			Expect(received):toHaveLength(0)
			Expect(server:GetStats().PayloadRejected >= 1):toBeTruthy()

			sender:FireServer({ Damage = 25 })
			Runtime.advanceFrames(2)
			Expect(received):toHaveLength(1)
			Expect(received[1].Damage):toBe(25)
		end)
	end)

	it("rejects oversized payloads", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server({ Payload = { MaxBytes = 300, MaxDepth = 4 } })
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			local received = 0
			combat.OnServerEvent:Connect(function()
				received += 1
			end)
			client:GetEvent("Combat"):FireServer(string.rep("x", 1000))
			Runtime.advanceFrames(3)
			Expect(received):toBe(0)
			Expect(server:GetStats().PayloadRejected >= 1):toBeTruthy()
		end)
	end)

	it("enforces event permissions", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			local calls = 0
			combat.OnServerEvent:Connect(function()
				calls += 1
			end)
			combat:SetPermission(function()
				return false, "PERMISSION_DENIED"
			end)
			client:GetEvent("Combat"):FireServer({})
			Runtime.advanceFrames(3)
			Expect(calls):toBe(0)
			Expect(server:GetStats().PermissionsDenied >= 1):toBeTruthy()

			combat:SetPermission(nil)
			client:GetEvent("Combat"):FireServer({})
			Runtime.advanceFrames(3)
			Expect(calls):toBe(1)
		end)
	end)

	it("uses a packet budget separate from the message rate limit", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server({
				RateLimit = { Rate = 1, Burst = 1, PacketRate = 100, PacketBurst = 100 },
			})
			env.client(player)
			local view = env.remoteView(player)
			for _ = 1, 5 do
				view:FireServer({ 999 })
			end
			Runtime.advanceFrames(2)
			local stats = server:GetStats()
			Expect(stats.MalformedPackets):toBe(5)
			Expect(stats.RateLimited):toBe(0)
		end)
	end)

	it("rate limits malformed packets before unpacking them", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server({
				RateLimit = { Rate = 1, Burst = 2, PacketRate = 1, PacketBurst = 2 },
			})
			env.client(player)
			local view = env.remoteView(player)
			for _ = 1, 5 do
				view:FireServer({ 999 })
			end
			Runtime.advanceFrames(2)
			local stats = server:GetStats()
			Expect(stats.MalformedPackets):toBe(2)
			Expect(stats.RateLimited):toBe(3)
		end)
	end)

	it("drops malformed packets without disturbing later traffic", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local view = env.remoteView(player)
			view:FireServer({ 999 })
			view:FireServer("garbage")
			Runtime.advanceFrames(2)
			Expect(server:GetStats().MalformedPackets >= 1):toBeTruthy()

			local combat = server:CreateEvent("Combat")
			local received = 0
			combat.OnServerEvent:Connect(function()
				received += 1
			end)
			client:GetEvent("Combat"):FireServer({})
			Runtime.advanceFrames(3)
			Expect(received):toBe(1)
		end)
	end)
end)

describe("Network middleware", function()
	it("runs middleware before handlers and can reject messages", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			local received = {}
			combat.OnServerEvent:Connect(function(_, data)
				table.insert(received, data)
			end)
			local token = server:Use(function(context, next)
				context.Data.Damage += 100
				return next(context)
			end)
			local sender = client:GetEvent("Combat")
			sender:FireServer({ Damage = 5 })
			Runtime.advanceFrames(3)
			Expect(received[1].Damage):toBe(105)

			server:Unuse(token)
			server:Use(function(context, next)
				return false, "BLOCKED"
			end)
			sender:FireServer({ Damage = 5 })
			Runtime.advanceFrames(3)
			Expect(received):toHaveLength(1)
			Expect(server:GetStats().MiddlewareRejected >= 1):toBeTruthy()
		end)
	end)

	it("runs client middleware on inbound events", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			local received = nil
			client:GetEvent("Combat").OnClientEvent:Connect(function(data)
				received = data
			end)
			client:Use(function(context, next)
				context.Data.Marker = "client"
				return next(context)
			end)
			combat:FireClient(player, { Value = 1 })
			Runtime.advanceFrames(3)
			Expect(received.Marker):toBe("client")
		end)
	end)
end)

describe("Network serializer and compression", function()
	it("round-trips encoded and compressed payloads through the wire", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local transportConfig = {
				Serializer = { Enabled = true },
				Compression = { Enabled = true, Threshold = 8, MinSavingsRatio = 1 },
			}
			local server = env.server(transportConfig)
			local client = env.client(player, transportConfig)
			local combat = server:CreateEvent("Combat")
			local received = nil
			combat.OnServerEvent:Connect(function(_, data)
				received = data
			end)
			local payload = {
				Name = "Thunder",
				Position = Vector3.new(1, 2, 3),
				Blob = string.rep("A", 500),
			}
			client:GetEvent("Combat"):FireServer(payload)
			Runtime.advanceFrames(3)
			Expect(received):toBeTruthy()
			Expect(received.Name):toBe("Thunder")
			Expect(received.Position.X):toBeNear(1)
			Expect(received.Position.Y):toBeNear(2)
			Expect(received.Position.Z):toBeNear(3)
			Expect(received.Blob):toBe(string.rep("A", 500))
			Expect(client:GetStats().CompressionSavingsBytes > 0):toBeTruthy()
		end)
	end)
end)

describe("Network statistics", function()
	it("reports message, batch, request and dispatch statistics", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local combat = server:CreateEvent("Combat", { Priority = "High" })
			local serverCombat = server:GetEvent("Combat")
			serverCombat.OnServerEvent:Connect(function() end)
			client:GetEvent("Combat"):FireServer({ A = 1 })
			serverCombat:FireClient(player, { B = 2 })
			server:OnRequest("Ping", function()
				return "pong"
			end)
			local promise = client:InvokeServer("Ping", {})
			Expect(Runtime.waitFor(function()
				return promise:GetStatus() ~= "Pending"
			end, 2)):toBeTruthy()
			Runtime.advanceFrames(2)

			local serverStats = server:GetStats()
			Expect(serverStats.MessagesReceived > 0):toBeTruthy()
			Expect(serverStats.MessagesSent > 0):toBeTruthy()
			Expect(serverStats.BatchesSent > 0):toBeTruthy()
			Expect(serverStats.AverageBatchSize > 0):toBeTruthy()
			Expect(serverStats.BytesSentEstimate > 0):toBeTruthy()
			Expect(serverStats.QueueDepth):toBe(0)
			Expect(serverStats.RequestsPending):toBe(0)
			Expect(serverStats.Dispatches > 0):toBeTruthy()
			Expect(serverStats.DispatchTimeMs >= 0):toBeTruthy()
			Expect(#serverStats.MessagesByPriority):toBe(5)

			local clientStats = client:GetStats()
			Expect(clientStats.RequestsSent):toBe(1)
			Expect(clientStats.MessagesSent > 0):toBeTruthy()
			Expect(clientStats.MessagesReceived > 0):toBeTruthy()
		end)
	end)

	it("skips dispatch timing when stats are disabled", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server({ Stats = false })
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			combat.OnServerEvent:Connect(function() end)
			client:GetEvent("Combat"):FireServer({})
			Runtime.advanceFrames(3)
			local stats = server:GetStats()
			Expect(stats.Dispatches):toBe(0)
			Expect(stats.DispatchTimeMs):toBe(0)
			Expect(stats.MessagesReceived > 0):toBeTruthy()
		end)
	end)
end)

describe("Network lifecycle and channels", function()
	it("supports channels with inherited defaults", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local channel = server:CreateChannel("Combat", { Priority = "High" })
			Expect(channel:GetName()):toBe("Combat")
			local hit = channel:CreateEvent("Hit")
			Expect(hit.Name):toBe("Combat/Hit")
			Expect(hit:GetPriority()):toBe("High")
			Expect(server:GetEvent("Combat/Hit")):toBe(hit)
			local received = nil
			server:GetEvent("Combat/Hit").OnServerEvent:Connect(function(_, data)
				received = data
			end)
			client:GetEvent("Combat/Hit"):FireServer({ Amount = 3 })
			Runtime.advanceFrames(3)
			Expect(received.Amount):toBe(3)
		end)
	end)

	it("rejects pending invocations on destroy and cancels timers", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			env.client(player)
			local timerFired = false
			server:After(0.2, function()
				timerFired = true
			end)
			Runtime.advance(0.1)
			Expect(timerFired):toBeFalsy()
			local promise = server:InvokeClient(player, "NeverSent", {})
			server:Destroy()
			local captured = nil
			promise:Catch(function(err)
				captured = err
			end)
			Expect(promise:GetStatus()):toBe("Rejected")
			Expect(captured.Code):toBe("DESTROYED")
			Runtime.advance(0.5)
			Expect(timerFired):toBeFalsy()
		end)
	end)

	it("cleans up queued work and pending invocations when a player leaves", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			env.client(player)
			local combat = server:CreateEvent("Combat")
			combat:FireClient(player, { Queued = true })
			Expect(server:GetStats().QueueDepth):toBe(1)
			local promise = server:InvokeClient(player, "Never", {})
			Runtime.removePlayer(player)
			Expect(server:GetStats().QueueDepth):toBe(0)
			local captured = nil
			promise:Catch(function(err)
				captured = err
			end)
			Expect(promise:GetStatus()):toBe("Rejected")
			Expect(captured.Code):toBe("PLAYER_LEFT")
			Runtime.advanceFrames(2)
		end)
	end)

	it("rejects invalid configurations", function()
		Expect(function()
			ThunderNet.Server({ Batch = { MaxBatchSize = 0 } })
		end):toThrow()
		Expect(function()
			ThunderNet.Server({ Payload = { MaxBytes = 0, MaxDepth = 1 } })
		end):toThrow()
	end)


end)

describe("Network helpers, presets, and queue limits", function()
	it("initializes with ThunderNet.Init and creates typed handles", function()
		local name = "TNInit" .. tostring(math.random(1, 1000000000))
		local net = ThunderNet.Init({ Name = name })
		local ok, err = pcall(function()
			Expect(net:IsServer()):toBeTruthy()
			local event = ThunderNet.Event(net, "Ping")
			Expect(event.Name):toBe("Ping")
			Expect(net:GetEvent("Ping")):toBe(event)
		end)
		net:Destroy()
		if not ok then
			error(err, 0)
		end
		Expect(replicatedStorage:FindFirstChild(name)):toBeNil()
	end)

	it("applies the Minimal preset and allows explicit overrides", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server({ Preset = "Minimal" })
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			local serverCount = 0
			combat.OnServerEvent:Connect(function()
				serverCount += 1
			end)
			local clientCount = 0
			client:GetEvent("Combat").OnClientEvent:Connect(function()
				clientCount += 1
			end)
			client:GetEvent("Combat"):FireServer({})
			for index = 1, 100 do
				combat:FireClient(player, { Index = index })
			end
			Runtime.advanceFrames(3)
			Expect(serverCount):toBe(1)
			Expect(clientCount):toBe(100)
			local stats = server:GetStats()
			Expect(stats.Dispatches):toBe(0)
			Expect(stats.BatchesSent >= 4):toBeTruthy()
		end)

		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server({ Preset = "Minimal", Stats = true })
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			combat.OnServerEvent:Connect(function() end)
			client:GetEvent("Combat"):FireServer({})
			Runtime.advanceFrames(2)
			Expect(server:GetStats().Dispatches > 0):toBeTruthy()
		end)
	end)

	it("applies the Hardened preset and respects explicit payload overrides", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server({ Preset = "Hardened" })
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			local received = 0
			combat.OnServerEvent:Connect(function()
				received += 1
			end)
			client:GetEvent("Combat"):FireServer(string.rep("x", 20000))
			Runtime.advanceFrames(2)
			Expect(received):toBe(0)
			Expect(server:GetStats().PayloadRejected > 0):toBeTruthy()
		end)

		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server({ Preset = "Hardened", Payload = { MaxBytes = 65536, MaxDepth = 8 } })
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			local received = 0
			combat.OnServerEvent:Connect(function()
				received += 1
			end)
			client:GetEvent("Combat"):FireServer(string.rep("x", 20000))
			Runtime.advanceFrames(2)
			Expect(received):toBe(1)
		end)
	end)

	it("rejects unknown presets", function()
		Expect(function()
			ThunderNet.Server({ Name = "TNBadPreset", Preset = "Nope" })
		end):toThrow()
		Expect(replicatedStorage:FindFirstChild("TNBadPreset")):toBeNil()
	end)

	it("drops messages that exceed the queue depth and reports overflow", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server({ Batch = { MaxQueueDepth = 1 } })
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			local received = 0
			client:GetEvent("Combat").OnClientEvent:Connect(function()
				received += 1
			end)
			combat:FireClient(player, { Index = 1 })
			combat:FireClient(player, { Index = 2 })
			Runtime.advanceFrames(3)
			Expect(received):toBe(1)
			Expect(server:GetStats().QueueOverflow):toBe(1)
		end)
	end)
end)

describe("Network handshake and serializer fallback", function()
	it("publishes protocol/config metadata and rejects codec mismatches", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			env.server({ Serializer = { Enabled = true } })
			local folder = replicatedStorage:FindFirstChild(env.name)
			Expect(folder):toBeTruthy()
			local configuration = folder and folder:FindFirstChild("Configuration")
			Expect(configuration):toBeTruthy()
			Expect(configuration:GetAttribute("ProtocolVersion")):toBe(1)
			Expect(configuration:GetAttribute("SerializerEnabled")):toBe(true)
			Expect(configuration:GetAttribute("CompressionEnabled")):toBe(false)

			Runtime.setClient(player)
			local ok, err = pcall(ThunderNet.Client, { Name = env.name })
			Runtime.clearClient()
			Expect(ok):toBeFalsy()
			Expect(tostring(err)):toInclude("Serializer")
		end)
	end)

	it("falls back to native payloads when configured", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local config = {
				Serializer = { Enabled = true, FallbackToNative = true },
				Compression = { Enabled = false },
			}
			local server = env.server(config)
			local client = env.client(player, config)
			local combat = server:CreateEvent("Combat")
			local received = nil
			combat.OnServerEvent:Connect(function(_, data)
				received = data
			end)
			client:GetEvent("Combat"):FireServer({ Target = Instance.new("Model") })
			Runtime.advanceFrames(2)
			Expect(received):toBeTruthy()
			Expect(typeof(received.Target)):toBe("Instance")
		end)
	end)
end)

describe("Network hooks", function()
	it("reports malformed packets, overload, and rate limits", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server({
				RateLimit = { Rate = 1, Burst = 1 },
				Batch = { MaxQueueDepth = 1 },
			})
			local client = env.client(player)
			local drops = {}
			local limits = {}
			server.OnDrop:Connect(function(payload)
				table.insert(drops, payload)
			end)
			server.OnRateLimited:Connect(function(payload)
				table.insert(limits, payload)
			end)

			local view = env.remoteView(player)
			view:FireServer({ 999 })
			Runtime.advanceFrames(1)

			local combat = server:CreateEvent("Combat")
			local sender = client:GetEvent("Combat")
			sender:FireServer({})
			sender:FireServer({})
			combat:FireClient(player, { Index = 1 })
			combat:FireClient(player, { Index = 2 })
			Runtime.advanceFrames(3)

			local malformed = false
			local overflow = false
			for _, payload in ipairs(drops) do
				if payload.Code == "MALFORMED_PACKET" then
					malformed = true
				elseif payload.Code == "QUEUE_OVERFLOW" then
					overflow = true
				end
			end
			Expect(malformed):toBeTruthy()
			Expect(overflow):toBeTruthy()
			Expect(#limits >= 1):toBeTruthy()
			Expect(limits[1].Player):toBe(player)
		end)
	end)

	it("reports request handler errors", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local errors = {}
			server.OnError:Connect(function(payload)
				table.insert(errors, payload)
			end)
			server:OnRequest("Broken", function()
				error("boom", 0)
			end)
			local promise = client:InvokeServer("Broken", {})
			Expect(Runtime.waitFor(function()
				return promise:GetStatus() ~= "Pending"
			end, 2)):toBeTruthy()
			local found = false
			for _, payload in ipairs(errors) do
				if payload.Code == "HANDLER_ERROR" then
					found = true
				end
			end
			Expect(found):toBeTruthy()
			Expect(promise:GetStatus()):toBe("Rejected")
		end)
	end)
end)

describe("Scoped middleware", function()
	it("runs per-event middleware and supports removal and rejection", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local combat = server:CreateEvent("Combat", {
				Middleware = {
					function(context, next)
						context.Data.Static = true
						return next(context)
					end,
				},
			})
			local other = server:CreateEvent("Other")
			local combatData = nil
			local otherData = nil
			combat.OnServerEvent:Connect(function(_, data)
				combatData = data
			end)
			other.OnServerEvent:Connect(function(_, data)
				otherData = data
			end)
			local senderCombat = client:GetEvent("Combat")
			local senderOther = client:GetEvent("Other")
			senderCombat:FireServer({})
			senderOther:FireServer({})
			Runtime.advanceFrames(3)
			Expect(combatData.Static):toBe(true)
			Expect(otherData.Static):toBeNil()

			local token = combat:Use(function(context, next)
				context.Data.Dynamic = true
				return next(context)
			end)
			senderCombat:FireServer({})
			Runtime.advanceFrames(3)
			Expect(combatData.Dynamic):toBe(true)
			combat:Unuse(token)
			senderCombat:FireServer({})
			Runtime.advanceFrames(3)
			Expect(combatData.Dynamic):toBeNil()

			local blocked = server:CreateEvent("Blocked", {
				Middleware = {
					function()
						return false, "NOPE"
					end,
				},
			})
			local blockedCalls = 0
			blocked.OnServerEvent:Connect(function()
				blockedCalls += 1
			end)
			local drops = {}
			server.OnDrop:Connect(function(payload)
				table.insert(drops, payload)
			end)
			client:GetEvent("Blocked"):FireServer({})
			Runtime.advanceFrames(2)
			Expect(blockedCalls):toBe(0)
			local rejected = false
			for _, payload in ipairs(drops) do
				if payload.Code == "MIDDLEWARE_REJECTED" and payload.Channel == "Blocked" then
					rejected = true
				end
			end
			Expect(rejected):toBeTruthy()
		end)
	end)

	it("runs outbound middleware and supports removal and rejection", function()
		withNetworks(function(env)
			local player = env.player("Alice")
			local server = env.server()
			local client = env.client(player)
			local combat = server:CreateEvent("Combat")
			local received = nil
			local receivedCount = 0
			client:GetEvent("Combat").OnClientEvent:Connect(function(data)
				received = data
				receivedCount += 1
			end)
			local observedPlayer = nil
			local token = server:UseOutbound(function(context, next)
				if context.Channel == "Combat" then
					context.Data.Outbound = true
				end
				observedPlayer = context.Player
				return next(context)
			end)
			combat:FireClient(player, {})
			Runtime.advanceFrames(3)
			Expect(received.Outbound):toBe(true)
			Expect(observedPlayer):toBe(player)

			local blockedToken = server:UseOutbound(function()
				return false, "BLOCKED"
			end)
			combat:FireClient(player, {})
			Runtime.advanceFrames(3)
			Expect(receivedCount):toBe(1)
			Expect(server:GetStats().OutboundRejected):toBe(1)

			server:UnuseOutbound(blockedToken)
			combat:FireClient(player, {})
			Runtime.advanceFrames(3)
			Expect(receivedCount):toBe(2)
			Expect(received.Outbound):toBe(true)

			server:UnuseOutbound(token)
			combat:FireClient(player, {})
			Runtime.advanceFrames(3)
			Expect(received.Outbound):toBeNil()
		end)
	end)
end)
