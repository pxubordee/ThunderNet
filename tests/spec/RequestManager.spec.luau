--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Protocol = require(ThunderNetFolder.Core.Protocol)
local RequestManager = require(ThunderNetFolder.Core.RequestManager)

local describe, it = TestHarness.describe, TestHarness.it

local function newManager(overrides, side)
	local sent = {}
	local config = {
		Timeout = 2,
		MaxAttempts = 3,
		BackoffBase = 0.5,
		BackoffMax = 4,
		Jitter = 0,
		DedupeTtl = 30,
		DedupeMaxEntries = 8,
		Random = function()
			return 0.5
		end,
	}
	if overrides then
		for key, value in pairs(overrides) do
			config[key] = value
		end
	end
	local manager = RequestManager.new(side or "Server", function(destination, envelope, priority)
		table.insert(sent, {
			Destination = destination,
			Envelope = envelope,
			Priority = priority,
		})
	end, config)
	return manager, sent
end

local function lastSent(sent)
	return sent[#sent]
end

local function awaitRejection(promise)
	local captured = nil
	promise:Catch(function(err)
		captured = err
	end)
	return captured
end

describe("RequestManager outbound", function()
	it("sends a request envelope with a valid unique id", function()
		local manager, sent = newManager()
		local player = { UserId = 1 }
		local first = manager:Request(player, "Purchase", { Item = 1 }, 0)
		local second = manager:Request(player, "Purchase", { Item = 2 }, 0)
		Expect(sent):toHaveLength(2)
		local firstEnvelope = sent[1].Envelope
		local secondEnvelope = sent[2].Envelope
		Expect(firstEnvelope[1]):toBe(Protocol.Ops.Request)
		Expect(firstEnvelope[2]):toBe("Purchase")
		Expect(Protocol.ValidateRequestId(firstEnvelope[3], 64)):toBeTruthy()
		Expect(secondEnvelope[3]):toNotBe(firstEnvelope[3])
		Expect(sent[1].Destination):toBe(player)
		Expect(manager:GetPendingCount()):toBe(2)
		first:Cancel()
		second:Cancel()
		manager:Destroy()
	end)

	it("resolves the promise when a response arrives", function()
		local manager, sent = newManager()
		local player = { UserId = 1 }
		local promise = manager:Request(player, "Purchase", {}, 0)
		local id = sent[1].Envelope[3]
		local responded = manager:HandleResponse(Protocol.Response(id, true, { Success = true }), player)
		Expect(responded):toBeTruthy()
		Expect(promise:GetStatus()):toBe("Resolved")
		Expect((promise:Await()).Success):toBeTruthy()
		Expect(manager:GetPendingCount()):toBe(0)
		manager:Destroy()
	end)

	it("rejects the promise when the response signals an error", function()
		local manager, sent = newManager()
		local player = { UserId = 1 }
		local promise = manager:Request(player, "Purchase", {}, 0)
		local id = sent[1].Envelope[3]
		manager:HandleResponse(Protocol.Response(id, false, {
			Code = "DENIED",
			Message = "not allowed",
		}), player)
		local rejection = awaitRejection(promise)
		Expect(rejection.Code):toBe("DENIED")
		Expect(promise:GetStatus()):toBe("Rejected")
		manager:Destroy()
	end)

	it("ignores responses from the wrong sender and unknown ids", function()
		local manager, sent = newManager()
		local alice = { UserId = 1 }
		local bob = { UserId = 2 }
		local promise = manager:Request(alice, "Purchase", {}, 0)
		local id = sent[1].Envelope[3]
		Expect(manager:HandleResponse(Protocol.Response(id, true, "forged"), bob)):toBeFalsy()
		Expect(promise:GetStatus()):toBe("Pending")
		Expect(manager:HandleResponse(Protocol.Response("req-unknown", true, "x"), alice)):toBeFalsy()
		Expect(manager:GetPendingCount()):toBe(1)
		promise:Cancel()
		manager:Destroy()
	end)

	it("times out without retries and notifies the receiver", function()
		local manager, sent = newManager({ MaxAttempts = 1, Timeout = 1 })
		local player = { UserId = 1 }
		local promise = manager:Request(player, "Purchase", {}, 0)
		manager:Step(0.5)
		Expect(promise:GetStatus()):toBe("Pending")
		manager:Step(1)
		local rejection = awaitRejection(promise)
		Expect(rejection.Code):toBe("TIMEOUT")
		Expect(promise:GetStatus()):toBe("Rejected")
		Expect(manager.counters.TimedOut):toBe(1)
		Expect(manager:GetPendingCount()):toBe(0)
		local cancelEnvelope = lastSent(sent).Envelope
		Expect(cancelEnvelope[1]):toBe(Protocol.Ops.Cancel)
		manager:Destroy()
	end)

	it("retries with backoff up to the attempt budget", function()
		local manager, sent = newManager({ MaxAttempts = 2, Timeout = 1, BackoffBase = 0.5, BackoffMax = 4 })
		local player = { UserId = 1 }
		local promise = manager:Request(player, "Purchase", {}, 0)
		Expect(#sent):toBe(1)

		manager:Step(1)
		Expect(#sent):toBe(1)
		manager:Step(1.4)
		Expect(#sent):toBe(1)
		manager:Step(1.5)
		Expect(#sent):toBe(2)
		Expect(lastSent(sent).Envelope[1]):toBe(Protocol.Ops.Request)
		Expect(manager.counters.Retries):toBe(1)

		manager:Step(2.5)
		local rejection = awaitRejection(promise)
		Expect(rejection.Code):toBe("TIMEOUT")
		Expect(manager.counters.TimedOut):toBe(1)
		Expect(#sent):toBe(3)
		Expect(lastSent(sent).Envelope[1]):toBe(Protocol.Ops.Cancel)
		manager:Destroy()
	end)

	it("cancels pending requests and sends a cancel envelope", function()
		local manager, sent = newManager()
		local player = { UserId = 1 }
		local promise = manager:Request(player, "Purchase", {}, 0)
		local id = sent[1].Envelope[3]
		promise:Cancel()
		Expect(promise:GetStatus()):toBe("Cancelled")
		Expect(manager:GetPendingCount()):toBe(0)
		Expect(lastSent(sent).Envelope[1]):toBe(Protocol.Ops.Cancel)
		Expect(lastSent(sent).Envelope[2]):toBe(id)
		Expect(manager:HandleResponse(Protocol.Response(id, true, "late"), player)):toBeFalsy()
		manager:Destroy()
	end)

	it("rejects pending requests for departing players", function()
		local manager = newManager()
		local alice = { UserId = 1 }
		local bob = { UserId = 2 }
		local alicePromise = manager:Request(alice, "Purchase", {}, 0)
		local bobPromise = manager:Request(bob, "Purchase", {}, 0)
		manager:OnPlayerRemoving(alice)
		local rejection = awaitRejection(alicePromise)
		Expect(rejection.Code):toBe("PLAYER_LEFT")
		Expect(bobPromise:GetStatus()):toBe("Pending")
		Expect(manager:GetPendingCount()):toBe(1)
		bobPromise:Cancel()
		manager:Destroy()
	end)
end)

describe("RequestManager inbound dedupe", function()
	it("returns cached responses for duplicate requests", function()
		local manager = newManager()
		local player = { UserId = 1 }
		local response = Protocol.Response("req-1", true, { Value = 1 })
		local status = manager:BeginIncoming(player, "Purchase", "req-1", 0)
		Expect(status):toBe("execute")
		manager:CompleteIncoming(player, "Purchase", "req-1", response, 0)
		local secondStatus, cached = manager:BeginIncoming(player, "Purchase", "req-1", 1)
		Expect(secondStatus):toBe("cached")
		Expect(cached):toBe(response)
		Expect(manager:GetDedupeCount(player)):toBe(1)
		manager:Destroy()
	end)

	it("rejects a replayed request id on a different channel", function()
		local manager = newManager()
		local player = { UserId = 1 }
		manager:CompleteIncoming(player, "Purchase", "req-1", Protocol.Response("req-1", true, true), 0)
		local status, cached = manager:BeginIncoming(player, "Inventory", "req-1", 1)
		Expect(status):toBe("mismatch")
		Expect(cached):toBeNil()
		manager:Destroy()
	end)

	it("suppresses duplicate requests while the same channel is in flight", function()
		local manager = newManager()
		local player = { UserId = 1 }
		Expect(manager:BeginIncoming(player, "Purchase", "req-1", 0)):toBe("execute")
		Expect(manager:BeginIncoming(player, "Purchase", "req-1", 0.1)):toBe("inflight")
		Expect(manager:BeginIncoming(player, "Inventory", "req-1", 0.2)):toBe("mismatch")
		manager:CompleteIncoming(player, "Purchase", "req-1", Protocol.Response("req-1", true, true), 0.3)
		Expect(manager:BeginIncoming(player, "Purchase", "req-1", 0.4)):toBe("cached")
		manager:Destroy()
	end)

	it("expires cached responses after the dedupe window", function()
		local manager = newManager({ DedupeTtl = 10 })
		local player = { UserId = 1 }
		manager:CompleteIncoming(player, "Purchase", "req-1", Protocol.Response("req-1", true, 1), 0)
		Expect(manager:BeginIncoming(player, "Purchase", "req-1", 9)):toBe("cached")
		Expect(manager:BeginIncoming(player, "Purchase", "req-1", 11)):toBe("execute")
		manager:Destroy()
	end)

	it("suppresses requests that were cancelled by the sender", function()
		local manager = newManager()
		local player = { UserId = 1 }
		manager:HandleCancel(player, "req-2", 0)
		Expect(manager:BeginIncoming(player, "Purchase", "req-2", 1)):toBe("cancelled")
		manager:Destroy()
	end)

	it("evicts the oldest entries beyond the dedupe limit", function()
		local manager = newManager({ DedupeMaxEntries = 2 })
		local player = { UserId = 1 }
		manager:CompleteIncoming(player, "Purchase", "req-1", Protocol.Response("req-1", true, 1), 0)
		manager:CompleteIncoming(player, "Purchase", "req-2", Protocol.Response("req-2", true, 2), 0)
		manager:CompleteIncoming(player, "Purchase", "req-3", Protocol.Response("req-3", true, 3), 0)
		Expect(manager:GetDedupeCount(player)):toBe(2)
		Expect(manager:BeginIncoming(player, "Purchase", "req-1", 1)):toBe("execute")
		manager:Destroy()
	end)

	it("clears player state on removal", function()
		local manager = newManager()
		local player = { UserId = 1 }
		manager:CompleteIncoming(player, "Purchase", "req-1", Protocol.Response("req-1", true, 1), 0)
		manager:HandleCancel(player, "req-2", 0)
		manager:OnPlayerRemoving(player)
		Expect(manager:GetDedupeCount(player)):toBe(0)
		Expect(manager:BeginIncoming(player, "Purchase", "req-1", 1)):toBe("execute")
		Expect(manager:BeginIncoming(player, "Purchase", "req-2", 1)):toBe("execute")
		manager:Destroy()
	end)
end)

describe("RequestManager lifecycle", function()
	it("rejects pending requests on destroy and refuses new work", function()
		local manager, _sent = newManager()
		local promise = manager:Request({ UserId = 1 }, "Purchase", {}, 0)
		manager:Destroy()
		local rejection = awaitRejection(promise)
		Expect(rejection.Code):toBe("DESTROYED")
		Expect(function()
			manager:Request({ UserId = 1 }, "Purchase", {}, 0)
		end):toThrow()
	end)

	it("honors per-request timeout and attempt options", function()
		local manager, sent = newManager({ MaxAttempts = 3, Timeout = 5 })
		local player = { UserId = 1 }
		local promise = manager:Request(player, "Purchase", {}, 0, { Timeout = 1, MaxAttempts = 1 })
		manager:Step(0.9)
		Expect(promise:GetStatus()):toBe("Pending")
		manager:Step(1)
		local rejection = awaitRejection(promise)
		Expect(rejection.Code):toBe("TIMEOUT")
		Expect(#sent):toBe(2)
		Expect(lastSent(sent).Envelope[1]):toBe(Protocol.Ops.Cancel)
		manager:Destroy()
	end)

	it("disables retries for non-idempotent requests", function()
		local manager, sent = newManager({ MaxAttempts = 3, Timeout = 1 })
		local player = { UserId = 1 }
		local promise = manager:Request(player, "Purchase", {}, 0, { Idempotent = false })
		manager:Step(1)
		local rejection = awaitRejection(promise)
		Expect(rejection.Code):toBe("TIMEOUT")
		Expect(#sent):toBe(2)
		Expect(lastSent(sent).Envelope[1]):toBe(Protocol.Ops.Cancel)
		manager:Destroy()
	end)

	it("limits retries per request while keeping global backoff", function()
		local manager, sent = newManager({ MaxAttempts = 5, Timeout = 1, BackoffBase = 0.5 })
		local player = { UserId = 1 }
		local promise = manager:Request(player, "Purchase", {}, 0, { MaxAttempts = 2 })
		manager:Step(1)
		Expect(#sent):toBe(1)
		manager:Step(1.5)
		Expect(#sent):toBe(2)
		manager:Step(2.5)
		local rejection = awaitRejection(promise)
		Expect(rejection.Code):toBe("TIMEOUT")
		Expect(#sent):toBe(3)
		manager:Destroy()
	end)

	it("rejects invalid per-request options", function()
		local manager = newManager()
		Expect(function()
			manager:Request({ UserId = 1 }, "Purchase", {}, 0, { Timeout = 0 })
		end):toThrow()
		Expect(function()
			manager:Request({ UserId = 1 }, "Purchase", {}, 0, { MaxAttempts = 0 })
		end):toThrow()
		manager:Destroy()
	end)

	it("validates server destinations and configuration", function()
		Expect(function()
			RequestManager.new("Server", function() end, { Timeout = 0 })
		end):toThrow()
		local manager = newManager()
		Expect(function()
			manager:Request(nil, "Purchase", {}, 0)
		end):toThrow()
		manager:Destroy()
	end)
end)
