--!nocheck
-- ThunderNet CPU benchmarks on the Luau CLI simulated Roblox environment.
--
-- These numbers measure framework CPU cost in a single process with a fake
-- RemoteEvent transport. They are NOT network bandwidth, latency or engine
-- performance measurements. Run benchmarks/StudioBenchmarks.server.luau inside
-- Roblox Studio for engine-side numbers.

local RobloxShim = require("../../tests/cli/RobloxShim")
local ModuleLoader = require("../../tests/cli/ModuleLoader")
local TreeBuilder = require("../../tests/cli/TreeBuilder")
local sources = require("../../tests/cli/generated/AllModules")

local realClock = os.clock
local shim = RobloxShim.new()
local loader = ModuleLoader.new(shim, sources)
local replicated = shim.game:GetService("ReplicatedStorage")
TreeBuilder.build(shim, sources, "src", "ThunderNet", replicated)

local ThunderNet = loader:Require(replicated.ThunderNet)
local Signal = loader:Require(replicated.ThunderNet.Utilities.Signal)
local Middleware = loader:Require(replicated.ThunderNet.Features.Middleware)
local Batcher = loader:Require(replicated.ThunderNet.Features.Batcher)
local Serializer = loader:Require(replicated.ThunderNet.Features.Serializer)
local Compression = loader:Require(replicated.ThunderNet.Features.Compression)
local Validator = loader:Require(replicated.ThunderNet.Security.Validator)

local results = {}
local function record(name, operations, elapsedSeconds, unit, note)
	table.insert(results, {
		Name = name,
		Operations = operations,
		ElapsedMs = elapsedSeconds * 1000,
		PerSecond = operations / elapsedSeconds,
		Unit = unit or "ops",
		Note = note or "",
	})
end

local function timeIt(fn)
	collectgarbage("collect")
	local start = realClock()
	fn()
	return realClock() - start
end

-- Signal emission -------------------------------------------------------------
do
	local signal = Signal.new()
	local sink = 0
	signal:Connect(function(value)
		sink += value
	end)
	local iterations = 500000
	local elapsed = timeIt(function()
		for index = 1, iterations do
			signal:Fire(index)
		end
	end)
	record("Signal emit (1 handler)", iterations, elapsed, "emits", "sink=" .. tostring(sink))
	signal:Destroy()
end

-- Middleware chain ------------------------------------------------------------
do
	local pipeline = Middleware.new()
	for _ = 1, 5 do
		pipeline:Use(function(context, next)
			context.Data.Value += 1
			return next(context)
		end)
	end
	local iterations = 100000
	local elapsed = timeIt(function()
		for _ = 1, iterations do
			pipeline:Run({
				Data = { Value = 0 },
				Channel = "Bench",
				Kind = "Event",
				Side = "Server",
			})
		end
	end)
	record("Middleware chain (5 layers)", iterations, elapsed, "runs", "includes context allocation")
	pipeline:Destroy()
end

-- Batcher ----------------------------------------------------------------
do
	local batches = 0
	local batcher = Batcher.new({
		MaxBatchSize = 128,
		MaxBatchBytes = 1e9,
	}, function(_destination, _reliable, messages)
		batches += 1
	end)
	local iterations = 100000
	local elapsed = timeIt(function()
		for index = 1, iterations do
			batcher:Push("destination", { index }, 3, true, 16, 0)
		end
		batcher:Step(0)
	end)
	record("Batcher enqueue+flush", iterations, elapsed, "messages", batches .. " batches of up to 128")
	batcher:Destroy()
end

-- Serializer ---------------------------------------------------------------
do
	local sample = {
		Name = "ThunderNet",
		Position = shim.Vector3.new(1, 2, 3),
		Counts = { 1, 2, 3, 4, 5 },
		Nested = { Flag = true, Ratio = 0.5, Label = "payload" },
	}
	local encoded = Serializer.Encode(sample)
	local iterations = 50000
	local elapsedEncode = timeIt(function()
		for _ = 1, iterations do
			Serializer.Encode(sample)
		end
	end)
	record("Serializer encode (nested payload)", iterations, elapsedEncode, "encodes", #encoded .. " bytes/result")
	local elapsedDecode = timeIt(function()
		for _ = 1, iterations do
			Serializer.Decode(encoded)
		end
	end)
	record("Serializer decode (nested payload)", iterations, elapsedDecode, "decodes", #encoded .. " bytes/input")
end

-- Compression --------------------------------------------------------------
do
	local repetitive = string.rep("A", 10000)
	local compressed = Compression.RLE.Encode(repetitive)
	local iterations = 2000
	local elapsedEncode = timeIt(function()
		for _ = 1, iterations do
			Compression.RLE.Encode(repetitive)
		end
	end)
	record("RLE compress 10KB runs", iterations, elapsedEncode, "compressions",
		("10KB -> %d bytes"):format(#compressed))
	local elapsedDecode = timeIt(function()
		for _ = 1, iterations do
			Compression.RLE.Decode(compressed, 20000)
		end
	end)
	record("RLE decompress 10KB runs", iterations, elapsedDecode, "decompressions", "output capped at 20KB")
end

-- Payload validation -------------------------------------------------------
do
	local payload = { Damage = 5, Name = "Target", Flags = { true, false, true } }
	local iterations = 100000
	local elapsed = timeIt(function()
		for _ = 1, iterations do
			Validator.CheckPayload(payload, { MaxBytes = 4096, MaxDepth = 8 })
		end
	end)
	record("Payload security walk", iterations, elapsed, "checks", "byte+depth+type limits")
end

-- Network end-to-end (simulated transport) ---------------------------------
local networkName = "ThunderNetBench"
local server = ThunderNet.Server({
	Name = networkName,
	Stats = true,
	Batch = { MaxBatchSize = 128, MaxBatchBytes = 32768 },
	Request = { Timeout = 5, MaxAttempts = 1 },
	RateLimit = { Rate = 1000000, Burst = 1000000 },
	Payload = { MaxBytes = 65536, MaxDepth = 8 },
})
local player = shim.createPlayer("Benchmarker")
shim.setClientContext(player)
local client = ThunderNet.Client({
	Name = networkName,
	Batch = { MaxBatchSize = 128, MaxBatchBytes = 32768 },
	RateLimit = { Rate = 1000000, Burst = 1000000 },
	Request = { Timeout = 5, MaxAttempts = 1 },
})
shim.setClientContext(nil)

local outEvent = server:CreateEvent("BenchOut")
local outClient = client:GetEvent("BenchOut")
local outCount = 0
outClient.OnClientEvent:Connect(function()
	outCount += 1
end)

do
	local iterations = 10000
	local payload = { Value = 1, Label = "out" }
	local elapsed = timeIt(function()
		for _ = 1, iterations do
			outEvent:FireClient(player, payload)
		end
		while outCount < iterations do
			shim.advanceFrames(1)
			if shim.now() > 30 then
				break
			end
		end
	end)
	record("Network server->client event", iterations, elapsed, "deliveries",
		("%d/%d delivered, batches=%d"):format(outCount, iterations, server:GetStats().BatchesSent))
end

-- Native baseline: raw simulated RemoteEvent per-message dispatch.
do
	local folder = replicated:WaitForChild(networkName)
	local rawRemote = shim.Instance.new("RemoteEvent", "NativeBenchRemote")
	rawRemote.Parent = folder
	local view = shim.withClient(player, function()
		return folder:WaitForChild("NativeBenchRemote")
	end)
	local nativeCount = 0
	view.OnClientEvent:Connect(function()
		nativeCount += 1
	end)
	local iterations = 10000
	local payload = { Value = 1, Label = "out" }
	local elapsed = timeIt(function()
		for _ = 1, iterations do
			rawRemote:FireClient(player, payload)
		end
	end)
	record("Native RemoteEvent baseline (simulated)", iterations, elapsed, "sends",
		("%d received, no batching/dispatch layer"):format(nativeCount))

	-- Native large payload (same 2 KB table used by the ThunderNet comparison).
	local largeIterations = 2000
	local largePayload = { Blob = string.rep("A", 2000), Tag = "native" }
	local largeCount = 0
	view.OnClientEvent:Connect(function()
		largeCount += 1
	end)
	local largeElapsed = timeIt(function()
		for _ = 1, largeIterations do
			rawRemote:FireClient(player, largePayload)
		end
	end)
	record("Native RemoteEvent large payload (simulated)", largeIterations, largeElapsed, "sends",
		("%d received, raw transport only"):format(largeCount))

	-- Native client -> server (raw transport only).
	local rawUp = shim.Instance.new("RemoteEvent", "NativeBenchUp")
	rawUp.Parent = folder
	local upView = shim.withClient(player, function()
		return folder:WaitForChild("NativeBenchUp")
	end)
	local nativeUpCount = 0
	rawUp.OnServerEvent:Connect(function()
		nativeUpCount += 1
	end)
	local upIterations = 10000
	local upPayload = { Value = 2, Label = "up" }
	local upElapsed = timeIt(function()
		for _ = 1, upIterations do
			upView:FireServer(upPayload)
		end
	end)
	record("Native RemoteEvent client->server (simulated)", upIterations, upElapsed, "sends",
		("%d received, no validation"):format(nativeUpCount))
	rawUp:Destroy()

	-- Native unreliable lane (raw transport only).
	local rawUnreliable = shim.Instance.new("UnreliableRemoteEvent", "NativeBenchUnreliable")
	rawUnreliable.Parent = folder
	local unreliableView = shim.withClient(player, function()
		return folder:WaitForChild("NativeBenchUnreliable")
	end)
	local nativeUnreliableCount = 0
	unreliableView.OnClientEvent:Connect(function()
		nativeUnreliableCount += 1
	end)
	local unreliableIterations = 5000
	local unreliablePayload = { Trail = 1, Step = 0.1 }
	local unreliableElapsed = timeIt(function()
		for _ = 1, unreliableIterations do
			rawUnreliable:FireClient(player, unreliablePayload)
		end
	end)
	record("Native UnreliableRemoteEvent (simulated)", unreliableIterations, unreliableElapsed, "sends",
		("%d received, raw transport only"):format(nativeUnreliableCount))
	rawUnreliable:Destroy()

	rawRemote:Destroy()
end

-- Client -> server events --------------------------------------------------
local upEvent = server:CreateEvent("BenchUp")
local upCount = 0
upEvent.OnServerEvent:Connect(function()
	upCount += 1
end)
local upClient = client:GetEvent("BenchUp")

do
	local iterations = 10000
	local payload = { Value = 2, Label = "up" }
	local elapsed = timeIt(function()
		for _ = 1, iterations do
			upClient:FireServer(payload)
		end
		while upCount < iterations do
			shim.advanceFrames(1)
			if shim.now() > 60 then
				break
			end
		end
	end)
	record("Network client->server event", iterations, elapsed, "deliveries",
		("%d/%d delivered with rate+payload validation"):format(upCount, iterations))
end

-- Unreliable lane ---------------------------------------------------------
local fxEvent = server:CreateEvent("BenchFX", { Unreliable = true, Priority = "Low" })
local fxClient = client:GetEvent("BenchFX", { Unreliable = true, Priority = "Low" })
local fxCount = 0
fxClient.OnClientEvent:Connect(function()
	fxCount += 1
end)

do
	local iterations = 5000
	local payload = { Trail = 1, Step = 0.1 }
	local elapsed = timeIt(function()
		for _ = 1, iterations do
			fxEvent:FireClient(player, payload)
		end
		while fxCount < iterations do
			shim.advanceFrames(1)
			if shim.now() > 90 then
				break
			end
		end
	end)
	record("Network unreliable event", iterations, elapsed, "deliveries",
		("%d/%d delivered over UnreliableRemoteEvent"):format(fxCount, iterations))
end

-- Large payload without serializer/compression ------------------------------
local bigEvent = server:CreateEvent("BenchBig")
local bigClient = client:GetEvent("BenchBig")
local bigCount = 0
bigClient.OnClientEvent:Connect(function()
	bigCount += 1
end)

do
	local iterations = 2000
	local payload = { Blob = string.rep("A", 2000), Tag = "native" }
	local elapsed = timeIt(function()
		for _ = 1, iterations do
			bigEvent:FireClient(player, payload)
		end
		while bigCount < iterations do
			shim.advanceFrames(1)
			if shim.now() > 120 then
				break
			end
		end
	end)
	record("Network large payload (native)", iterations, elapsed, "deliveries",
		("%d/%d delivered, serializer+compression off"):format(bigCount, iterations))
end

-- RPC round-trips ----------------------------------------------------------
do
	server:OnRequest("BenchPing", function(_sender, data)
		return data
	end)
	local iterations = 500
	local promises = {}
	local elapsed = timeIt(function()
		for index = 1, iterations do
			promises[index] = client:InvokeServer("BenchPing", { Index = index })
		end
		local frames = 0
		while frames < 600 do
			local pending = 0
			for index = 1, iterations do
				if promises[index]:GetStatus() == "Pending" then
					pending += 1
				end
			end
			if pending == 0 then
				break
			end
			shim.advanceFrames(1)
			frames += 1
		end
	end)
	local resolved = 0
	for index = 1, iterations do
		if promises[index]:GetStatus() == "Resolved" then
			resolved += 1
		end
	end
	record("RPC round-trip", iterations, elapsed, "requests",
		("%d/%d resolved, batching+dedupe enabled"):format(resolved, iterations))
end

client:Destroy()
server:Destroy()

-- Serializer + compression enabled (same large payload) --------------------
do
	local config = {
		Serializer = { Enabled = true },
		Compression = { Enabled = true, Threshold = 8, MinSavingsRatio = 1 },
	}
	local compressedName = "ThunderNetBenchCompressed"
	local compressedServer = ThunderNet.Server({
		Name = compressedName,
		Stats = true,
		Batch = { MaxBatchSize = 128, MaxBatchBytes = 32768 },
		Request = { Timeout = 5, MaxAttempts = 1 },
		RateLimit = { Rate = 1000000, Burst = 1000000 },
		Payload = { MaxBytes = 65536, MaxDepth = 8 },
		Serializer = config.Serializer,
		Compression = config.Compression,
	})
	local compressedPlayer = shim.createPlayer("BenchmarkerCompressed")
	shim.setClientContext(compressedPlayer)
	local compressedClient = ThunderNet.Client({
		Name = compressedName,
		Batch = { MaxBatchSize = 128, MaxBatchBytes = 32768 },
		Request = { Timeout = 5, MaxAttempts = 1 },
		RateLimit = { Rate = 1000000, Burst = 1000000 },
		Serializer = config.Serializer,
		Compression = config.Compression,
	})
	shim.setClientContext(nil)
	local compressedEvent = compressedServer:CreateEvent("BenchBig")
	local compressedHandle = compressedClient:GetEvent("BenchBig")
	local delivered = 0
	compressedHandle.OnClientEvent:Connect(function()
		delivered += 1
	end)
	local iterations = 2000
	local payload = { Blob = string.rep("A", 2000), Tag = "native" }
	local elapsed = timeIt(function()
		for _ = 1, iterations do
			compressedEvent:FireClient(compressedPlayer, payload)
		end
		while delivered < iterations do
			shim.advanceFrames(1)
			if shim.now() > 120 then
				break
			end
		end
	end)
	local stats = compressedServer:GetStats()
	record("Network large payload (serialized+compressed)", iterations, elapsed, "deliveries",
		("%d/%d delivered, savings=%d bytes"):format(delivered, iterations, stats.CompressionSavingsBytes))
	compressedClient:Destroy()
	compressedServer:Destroy()
end

-- Report -------------------------------------------------------------------
print("")
print("ThunderNet CPU benchmarks (Luau CLI simulated Roblox environment)")
print(("="):rep(82))
print(("%-42s %12s %12s %10s  %s"):format("Benchmark", "ops", "ms", "ops/sec", "Notes"))
print(("-"):rep(82))
for _, result in ipairs(results) do
	print(("%-42s %12d %12.2f %10.0f  %s"):format(
		result.Name,
		result.Operations,
		result.ElapsedMs,
		result.PerSecond,
		result.Note
	))
end
print(("="):rep(82))
print("Simulated single-process transport: no real network latency, bandwidth or")
print("Roblox engine scheduling. Use Studio benchmarks for engine-side numbers.")
