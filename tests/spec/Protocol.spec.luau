--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Protocol = require(ThunderNetFolder.Core.Protocol)

local describe, it = TestHarness.describe, TestHarness.it

local limits = {
	MaxBatchMessages = 4,
	MaxNameLength = 16,
	MaxRequestIdLength = 16,
}

describe("Protocol", function()
	it("builds and validates a single event envelope", function()
		local envelope = Protocol.Event("Combat", { Damage = 5 })
		Expect(envelope[1]):toBe(Protocol.Ops.Event)
		local messages, err = Protocol.Unpack(envelope, limits)
		Expect(err):toBeNil()
		Expect(messages):toHaveLength(1)
		Expect(messages[1][2]):toBe("Combat")
		Expect(messages[1][3].Damage):toBe(5)
	end)

	it("builds and unpacks batches preserving order", function()
		local batch = Protocol.Batch({
			Protocol.Event("A", 1),
			Protocol.Event("B", 2),
			Protocol.Cancel("req-1"),
		})
		local messages, err = Protocol.Unpack(batch, limits)
		Expect(err):toBeNil()
		Expect(messages):toHaveLength(3)
		Expect(messages[1][2]):toBe("A")
		Expect(messages[2][2]):toBe("B")
		Expect(messages[3][1]):toBe(Protocol.Ops.Cancel)
	end)

	it("rejects non-table packets and unknown opcodes", function()
		Expect(select(2, Protocol.Unpack("nope", limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack(nil, limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack({ 99 }, limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack({}, limits))):toBeTruthy()
	end)

	it("rejects malformed event envelopes", function()
		Expect(select(2, Protocol.Unpack({ Protocol.Ops.Event }, limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack({ Protocol.Ops.Event, 5, 1 }, limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack({ Protocol.Ops.Event, "A", 1, 0, "extra" }, limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack({ Protocol.Ops.Event, string.rep("x", 17), 1 }, limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack({ Protocol.Ops.Event, "", 1 }, limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack({ Protocol.Ops.Event, "bad\ntext", 1 }, limits))):toBeTruthy()
	end)

	it("validates flags and requires string payloads when encoding flags are set", function()
		local okEnvelope = Protocol.Event("A", "encoded", Protocol.Flags.Serialized)
		Expect(select(2, Protocol.Unpack(okEnvelope, limits))):toBeNil()
		Expect(select(2, Protocol.Unpack(Protocol.Event("A", "x", 4), limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack(Protocol.Event("A", "x", -1), limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack(Protocol.Event("A", { 1 }, Protocol.Flags.Compressed), limits))):toBeTruthy()
	end)

	it("validates request ids", function()
		Expect(Protocol.ValidateRequestId("abc-123_x.y", 16)):toBeTruthy()
		Expect(Protocol.ValidateRequestId("", 16)):toBeFalsy()
		Expect(Protocol.ValidateRequestId("bad id", 16)):toBeFalsy()
		Expect(Protocol.ValidateRequestId("bad:id", 16)):toBeFalsy()
		Expect(Protocol.ValidateRequestId(string.rep("a", 17), 16)):toBeFalsy()
		Expect(Protocol.ValidateRequestId(5, 16)):toBeFalsy()
		Expect(Protocol.ValidateRequestId("ünïcode", 16)):toBeFalsy()
	end)

	it("validates request envelopes", function()
		local envelope = Protocol.Request("Combat", "req-1", { A = 1 })
		local messages, err = Protocol.Unpack(envelope, limits)
		Expect(err):toBeNil()
		Expect(messages[1][3]):toBe("req-1")
		Expect(select(2, Protocol.Unpack(Protocol.Request("Combat", "bad id", 1), limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack({ Protocol.Ops.Request, "A", "req-1" }, limits))):toBeTruthy()
	end)

	it("validates response envelopes including error shape", function()
		local success = Protocol.Response("req-1", true, { Value = 1 })
		Expect(select(2, Protocol.Unpack(success, limits))):toBeNil()
		local failure = Protocol.Response("req-1", false, { Code = "INTERNAL", Message = "failed" })
		Expect(select(2, Protocol.Unpack(failure, limits))):toBeNil()
		Expect(select(2, Protocol.Unpack(Protocol.Response("req-1", false, "oops"), limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack(Protocol.Response("req-1", false, { Code = 5 }), limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack(Protocol.Response("bad id", true, nil), limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack(Protocol.Response("req-1", "yes", nil), limits))):toBeTruthy()
	end)

	it("validates cancel envelopes", function()
		local messages, err = Protocol.Unpack(Protocol.Cancel("req-1"), limits)
		Expect(err):toBeNil()
		Expect(messages[1][2]):toBe("req-1")
		Expect(select(2, Protocol.Unpack({ Protocol.Ops.Cancel, "bad id" }, limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack({ Protocol.Ops.Cancel, "req-1", 1 }, limits))):toBeTruthy()
	end)

	it("rejects empty, oversized and nested batches", function()
		Expect(select(2, Protocol.Unpack(Protocol.Batch({}), limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack(Protocol.Batch({
			Protocol.Event("A", 1),
			Protocol.Event("A", 2),
			Protocol.Event("A", 3),
			Protocol.Event("A", 4),
			Protocol.Event("A", 5),
		}), limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack(Protocol.Batch({
			Protocol.Batch({ Protocol.Event("A", 1) }),
		}), limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack(Protocol.Batch({
			Protocol.Event("A", 1),
			Protocol.Event("A", 2),
			Protocol.Event("A", 3),
			Protocol.Event("A", 4),
		}), limits))):toBeNil()
	end)

	it("rejects malformed batch containers", function()
		Expect(select(2, Protocol.Unpack({ Protocol.Ops.Batch }, limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack({ Protocol.Ops.Batch, "not a table" }, limits))):toBeTruthy()
		Expect(select(2, Protocol.Unpack({ Protocol.Ops.Batch, { Protocol.Event("A", 1) }, "extra" }, limits))):toBeTruthy()
	end)
end)
