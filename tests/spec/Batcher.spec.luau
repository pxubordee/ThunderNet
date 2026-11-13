--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Batcher = require(ThunderNetFolder.Features.Batcher)

local describe, it = TestHarness.describe, TestHarness.it

local function newBatcher(config)
	local sent = {}
	local batcher = Batcher.new(config, function(destination, reliable, messages)
		table.insert(sent, {
			Destination = destination,
			Reliable = reliable,
			Messages = messages,
		})
	end)
	return batcher, sent
end

local function message(id)
	return { Id = id }
end

local function ids(messages)
	local result = {}
	for _, value in ipairs(messages) do
		table.insert(result, value.Id)
	end
	return result
end

describe("Batcher", function()
	it("flushes queued messages on Step with the default interval", function()
		local batcher, sent = newBatcher({})
		local player = { Name = "Alice" }
		batcher:Push(player, message(1), 3, true, 10, 0)
		batcher:Push(player, message(2), 3, true, 10, 0)
		Expect(batcher:GetQueueDepth()):toBe(2)
		batcher:Step(0)
		Expect(sent):toHaveLength(1)
		Expect(sent[1].Destination):toBe(player)
		Expect(sent[1].Reliable):toBeTruthy()
		Expect(ids(sent[1].Messages)):toEqual({ 1, 2 })
		Expect(batcher:GetQueueDepth()):toBe(0)
		batcher:Destroy()
	end)

	it("preserves FIFO order within the same priority", function()
		local batcher, sent = newBatcher({ MaxBatchSize = 100 })
		local player = { Name = "Alice" }
		for index = 1, 5 do
			batcher:Push(player, message(index), 3, true, 1, 0)
		end
		batcher:Step(0)
		Expect(ids(sent[1].Messages)):toEqual({ 1, 2, 3, 4, 5 })
		batcher:Destroy()
	end)

	it("splits batches by message count", function()
		local batcher, sent = newBatcher({ MaxBatchSize = 2 })
		local player = { Name = "Alice" }
		for index = 1, 5 do
			batcher:Push(player, message(index), 3, true, 1, 0)
		end
		batcher:Step(0)
		Expect(sent):toHaveLength(3)
		Expect(ids(sent[1].Messages)):toEqual({ 1, 2 })
		Expect(ids(sent[2].Messages)):toEqual({ 3, 4 })
		Expect(ids(sent[3].Messages)):toEqual({ 5 })
		batcher:Destroy()
	end)

	it("splits batches by byte budget but sends oversized messages alone", function()
		local batcher, sent = newBatcher({ MaxBatchBytes = 10, MaxBatchSize = 100 })
		local player = { Name = "Alice" }
		batcher:Push(player, message(1), 3, true, 6, 0)
		batcher:Push(player, message(2), 3, true, 6, 0)
		batcher:Push(player, message(3), 3, true, 50, 0)
		batcher:Step(0)
		Expect(sent):toHaveLength(3)
		Expect(ids(sent[1].Messages)):toEqual({ 1 })
		Expect(ids(sent[2].Messages)):toEqual({ 2 })
		Expect(ids(sent[3].Messages)):toEqual({ 3 })
		batcher:Destroy()
	end)

	it("never mixes messages for different destinations", function()
		local batcher, sent = newBatcher({ MaxBatchSize = 100 })
		local alice = { Name = "Alice" }
		local bob = { Name = "Bob" }
		batcher:Push(alice, message(1), 3, true, 1, 0)
		batcher:Push(bob, message(2), 3, true, 1, 0)
		batcher:Push(alice, message(3), 3, true, 1, 0)
		batcher:Step(0)
		Expect(sent):toHaveLength(2)
		for _, batch in ipairs(sent) do
			if batch.Destination == alice then
				Expect(ids(batch.Messages)):toEqual({ 1, 3 })
			else
				Expect(batch.Destination):toBe(bob)
				Expect(ids(batch.Messages)):toEqual({ 2 })
			end
		end
		batcher:Destroy()
	end)

	it("keeps reliable and unreliable lanes separate", function()
		local batcher, sent = newBatcher({})
		local player = { Name = "Alice" }
		batcher:Push(player, message(1), 3, true, 1, 0)
		batcher:Push(player, message(2), 3, false, 1, 0)
		batcher:Step(0)
		Expect(sent):toHaveLength(2)
		for _, batch in ipairs(sent) do
			if batch.Reliable then
				Expect(ids(batch.Messages)):toEqual({ 1 })
			else
				Expect(ids(batch.Messages)):toEqual({ 2 })
			end
		end
		batcher:Destroy()
	end)

	it("serves every non-empty priority level each flush", function()
		local batcher, sent = newBatcher({ MaxBatchSize = 100 })
		local player = { Name = "Alice" }
		batcher:Push(player, message("critical"), 1, true, 1, 0)
		batcher:Push(player, message("low"), 4, true, 1, 0)
		batcher:Push(player, message("background"), 5, true, 1, 0)
		batcher:Push(player, message("normal"), 3, true, 1, 0)
		batcher:Step(0)
		local delivered = ids(sent[1].Messages)
		Expect(delivered):toHaveLength(4)
		Expect(delivered[1]):toBe("critical")
		Expect(delivered):toContain("low")
		Expect(delivered):toContain("background")
		Expect(delivered):toContain("normal")
		batcher:Destroy()
	end)

	it("prevents lower priorities from starving under a tiny batch budget", function()
		local batcher, sent = newBatcher({ MaxBatchSize = 1 })
		local player = { Name = "Alice" }
		batcher:Push(player, message("critical-1"), 1, true, 1, 0)
		batcher:Push(player, message("background-1"), 5, true, 1, 0)
		batcher:Step(0)
		Expect(ids(sent[1].Messages)):toEqual({ "critical-1" })

		batcher:Push(player, message("critical-2"), 1, true, 1, 0)
		batcher:Step(0.1)
		Expect(ids(sent[2].Messages)):toEqual({ "background-1" })

		batcher:Step(0.2)
		Expect(ids(sent[3].Messages)):toEqual({ "critical-2" })
		batcher:Destroy()
	end)

	it("respects the flush interval and adaptive latency", function()
		local batcher, sent = newBatcher({ FlushInterval = 0.1 })
		local player = { Name = "Alice" }
		batcher:Push(player, message(1), 3, true, 1, 0)
		batcher:Step(0.05)
		Expect(sent):toHaveLength(0)
		batcher:Step(0.1)
		Expect(sent):toHaveLength(1)

		local adaptive, adaptiveSent = newBatcher({
			FlushInterval = 0,
			Adaptive = true,
			MaxLatency = 0.05,
			AdaptiveDepthThreshold = 2,
		})
		adaptive:Push(player, message(1), 3, true, 1, 0)
		adaptive:Push(player, message(2), 3, true, 1, 0)
		adaptive:Step(0.02)
		Expect(adaptiveSent):toHaveLength(0)
		adaptive:Step(0.06)
		Expect(adaptiveSent):toHaveLength(1)
		batcher:Destroy()
		adaptive:Destroy()
	end)

	it("discards queued work for removed destinations", function()
		local batcher, sent = newBatcher({})
		local alice = { Name = "Alice" }
		local bob = { Name = "Bob" }
		batcher:Push(alice, message(1), 3, true, 1, 0)
		batcher:Push(bob, message(2), 3, true, 1, 0)
		batcher:RemoveDestination(alice)
		batcher:Step(0)
		Expect(sent):toHaveLength(1)
		Expect(sent[1].Destination):toBe(bob)
		Expect(batcher:GetQueueDepth()):toBe(0)
		batcher:Destroy()
	end)

	it("sends unreliable messages individually by default", function()
		local batcher, sent = newBatcher({ MaxBatchSize = 100 })
		local player = { Name = "Alice" }
		for index = 1, 3 do
			batcher:Push(player, message(index), 3, false, 10, 0)
		end
		batcher:Step(0)
		Expect(sent):toHaveLength(3)
		for index = 1, 3 do
			Expect(sent[index].Reliable):toBeFalsy()
			Expect(ids(sent[index].Messages)):toEqual({ index })
		end
		batcher:Destroy()
	end)

	it("supports opt-in unreliable batching with byte limits", function()
		local batcher, sent = newBatcher({
			UnreliableBatchSize = 2,
			UnreliableMaxBytes = 1e9,
		})
		local player = { Name = "Alice" }
		for index = 1, 4 do
			batcher:Push(player, message(index), 3, false, 1, 0)
		end
		batcher:Step(0)
		Expect(sent):toHaveLength(2)
		Expect(ids(sent[1].Messages)):toEqual({ 1, 2 })
		Expect(ids(sent[2].Messages)):toEqual({ 3, 4 })
		batcher:Destroy()

		local byteCapped, byteSent = newBatcher({
			UnreliableBatchSize = 100,
			UnreliableMaxBytes = 10,
		})
		byteCapped:Push(player, message(1), 3, false, 6, 0)
		byteCapped:Push(player, message(2), 3, false, 6, 0)
		byteCapped:Step(0)
		Expect(byteSent):toHaveLength(2)
		byteCapped:Destroy()
	end)

	it("caps queue depth per lane and reports rejection", function()
		local batcher, sent = newBatcher({ MaxQueueDepth = 2 })
		local player = { Name = "Alice" }
		Expect(batcher:Push(player, message(1), 3, true, 1, 0)):toBeTruthy()
		Expect(batcher:Push(player, message(2), 3, true, 1, 0)):toBeTruthy()
		Expect(batcher:Push(player, message(3), 3, true, 1, 0)):toBeFalsy()
		batcher:Step(0)
		Expect(sent):toHaveLength(1)
		Expect(ids(sent[1].Messages)):toEqual({ 1, 2 })
		Expect(batcher:GetQueueDepth()):toBe(0)
		batcher:Destroy()
	end)

	it("validates pushes and rejects use after Destroy", function()
		local batcher = newBatcher({})
		Expect(function()
			batcher:Push("x", message(1), 9, true, 1, 0)
		end):toThrow()
		Expect(function()
			batcher:Push("x", "not a table", 3, true, 1, 0)
		end):toThrow()
		batcher:Destroy()
		Expect(function()
			batcher:Push("x", message(1), 3, true, 1, 0)
		end):toThrow()
	end)
end)
