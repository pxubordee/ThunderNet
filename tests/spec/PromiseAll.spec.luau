--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Promise = require(ThunderNetFolder.Utilities.Promise)

local describe, it = TestHarness.describe, TestHarness.it

describe("Promise.all", function()
	it("resolves all values in order", function()
		local first = Promise.new()
		local second = Promise.new()
		local combined = Promise.all({ first, second })
		second:Resolve("b")
		first:Resolve("a")
		Expect(combined:GetStatus()):toBe("Resolved")
		Expect(combined:Await()):toEqual({ "a", "b" })
	end)

	it("resolves immediately for an empty list", function()
		local combined = Promise.all({})
		Expect(combined:GetStatus()):toBe("Resolved")
		Expect(combined:Await()):toEqual({})
	end)

	it("rejects as soon as one promise rejects", function()
		local first = Promise.new()
		local second = Promise.new()
		local combined = Promise.all({ first, second })
		local captured = nil
		combined:Catch(function(err)
			captured = err
		end)
		first:Reject("boom")
		Expect(combined:GetStatus()):toBe("Rejected")
		Expect(captured):toBe("boom")
		second:Resolve("ignored")
	end)

	it("accepts plain values alongside promises", function()
		local promise = Promise.new()
		local combined = Promise.all({ 1, promise, "raw" })
		promise:Resolve(2)
		Expect(combined:Await()):toEqual({ 1, 2, "raw" })
	end)
end)
