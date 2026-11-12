--!nocheck
-- ThunderNet engine-side benchmarks for Roblox Studio.
--
-- Copy this file into ServerScriptService (or run it from the command bar while
-- in Play Solo) after syncing the project with Rojo. It measures CPU cost on
-- the server; client delivery and real network bandwidth cannot be measured
-- from a single server script and are intentionally not claimed here.
--
-- Results are printed to the output window. Numbers depend on the machine and
-- the Studio version; always re-run before making performance claims.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ThunderNet = require(ReplicatedStorage:WaitForChild("ThunderNet"))

local function benchmark(name, iterations, fn)
	collectgarbage("collect")
	local started = os.clock()
	fn()
	local elapsed = os.clock() - started
	print(("%-46s %10d ops %10.2f ms %12.0f ops/sec"):format(
		name,
		iterations,
		elapsed * 1000,
		iterations / elapsed
	))
	return elapsed
end

local player = Players:GetPlayers()[1]
if player == nil then
	warn("ThunderNet benchmarks need at least one player; run in Play Solo.")
	return
end

local N = 5000
local payload = {
	Position = Vector3.new(1, 2, 3),
	Velocity = Vector3.new(0, 0, 1),
	Label = "snapshot",
}

-- Native per-call RemoteEvent sends.
do
	local remote = Instance.new("RemoteEvent")
	remote.Name = "ThunderNetNativeBench"
	remote.Parent = ReplicatedStorage
	benchmark("Native RemoteEvent FireClient", N, function()
		for _ = 1, N do
			remote:FireClient(player, payload)
		end
	end)
	remote:Destroy()
end

-- ThunderNet batched sends (enqueue + one heartbeat flush).
do
	local server = ThunderNet.Server({
		Name = "ThunderNetBench",
		Batch = { MaxBatchSize = 64, MaxBatchBytes = 16384 },
	})
	local event = server:CreateEvent("BenchOut")
	local eventPayload = {
		Position = Vector3.new(1, 2, 3),
		Velocity = Vector3.new(0, 0, 1),
		Label = "snapshot",
	}
	local elapsed = benchmark("ThunderNet FireClient (enqueue)", N, function()
		for _ = 1, N do
			event:FireClient(player, eventPayload)
		end
	end)
	RunService.Heartbeat:Wait()
	local stats = server:GetStats()
	print(("  batches=%d averageBatchSize=%.1f estimatedBytes=%d"):format(
		stats.BatchesSent,
		stats.AverageBatchSize,
		stats.BytesSentEstimate
	))
	print(("  measured enqueue+frame time: %.2f ms"):format(elapsed * 1000))
	server:Destroy()
end

-- Serializer and compression CPU cost.
do
	local serializer = ThunderNet.Types and require(ReplicatedStorage.ThunderNet.Features.Serializer)
	local compression = require(ReplicatedStorage.ThunderNet.Features.Compression)
	local sample = {
		Name = "ThunderNet",
		Position = Vector3.new(1, 2, 3),
		Counts = { 1, 2, 3, 4, 5 },
		Nested = { Flag = true, Ratio = 0.5, Label = "payload" },
	}
	local encodeIterations = 20000
	local encoded
	benchmark("Serializer encode", encodeIterations, function()
		for _ = 1, encodeIterations do
			encoded = serializer.Encode(sample)
		end
	end)
	benchmark("Serializer decode", encodeIterations, function()
		for _ = 1, encodeIterations do
			serializer.Decode(encoded)
		end
	end)
	local repetitive = string.rep("A", 10000)
	local compressed
	local compressionIterations = 1000
	benchmark("RLE compress 10KB", compressionIterations, function()
		for _ = 1, compressionIterations do
			compressed = compression.RLE.Encode(repetitive)
		end
	end)
	benchmark("RLE decompress 10KB", compressionIterations, function()
		for _ = 1, compressionIterations do
			compression.RLE.Decode(compressed, 20000)
		end
	end)
end

print("ThunderNet Studio benchmark finished.")
