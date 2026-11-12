--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Runtime = require(script.Parent.Parent.Support.Runtime)
local Promise = require(ThunderNetFolder.Utilities.Promise)

local describe, it = TestHarness.describe, TestHarness.it

describe("Promise", function()
	it("resolves values and runs AndThen callbacks", function()
		local promise = Promise.new()
		local received = {}
		promise:AndThen(function(value)
			table.insert(received, "a" .. tostring(value))
		end)
		promise:AndThen(function(value)
			table.insert(received, "b" .. tostring(value))
		end)
		promise:Resolve(7)
		Expect(promise:GetStatus()):toBe("Resolved")
		Expect(received):toEqual({ "a7", "b7" })
		Expect(promise:Await()):toBe(7)
	end)

	it("supports Await after asynchronous resolution", function()
		local promise = Promise.new()
		task.delay(0.05, function()
			promise:Resolve("later")
		end)
		Expect(promise:Await()):toBe("later")
	end)

	it("rejects and lets Catch handle the error", function()
		local promise = Promise.new()
		local caught = nil
		promise:Catch(function(err)
			caught = err
		end)
		promise:Reject("boom")
		Expect(promise:GetStatus()):toBe("Rejected")
		Expect(caught):toBe("boom")
		Expect(function()
			promise:Await()
		end):toThrow()
	end)

	it("chains transformed values through AndThen", function()
		local promise = Promise.new()
		local derived = promise:AndThen(function(value)
			return value * 2
		end)
		promise:Resolve(21)
		Expect(derived:GetStatus()):toBe("Resolved")
		Expect(derived:Await()):toBe(42)
	end)

	it("rejects the derived promise when an AndThen callback throws", function()
		local promise = Promise.new()
		local derived = promise:AndThen(function()
			error("handler failed", 0)
		end)
		promise:Resolve(1)
		Expect(derived:GetStatus()):toBe("Rejected")
		local ok, err = pcall(function()
			derived:Await()
		end)
		Expect(ok):toBeFalsy()
		Expect(tostring(err)):toInclude("handler failed")
	end)

	it("propagates rejections to downstream Catch handlers", function()
		local promise = Promise.new()
		local seen = nil
		promise
			:AndThen(function()
				error("must not run")
			end)
			:Catch(function(err)
				seen = err
			end)
		promise:Reject("original")
		Expect(seen):toBe("original")
	end)

	it("cancels pending promises and invokes cancel hooks once", function()
		local promise = Promise.new()
		local hookCalls = 0
		promise:OnCancel(function()
			hookCalls = hookCalls + 1
		end)
		local rejection = nil
		promise:Catch(function(err)
			rejection = err
		end)
		promise:Cancel()
		promise:Cancel()
		Expect(promise:GetStatus()):toBe("Cancelled")
		Expect(hookCalls):toBe(1)
		Expect(rejection.Code):toBe("CANCELLED")
		Expect(function()
			promise:Await()
		end):toThrow()
	end)

	it("ignores cancellation after resolution", function()
		local promise = Promise.new()
		promise:Resolve("value")
		promise:Cancel()
		Expect(promise:GetStatus()):toBe("Resolved")
		Expect(promise:Await()):toBe("value")
	end)

	it("runs Finally on success and preserves the value", function()
		local promise = Promise.new()
		local finallyCalls = 0
		local derived = promise:Finally(function()
			finallyCalls = finallyCalls + 1
		end)
		promise:Resolve("kept")
		Expect(finallyCalls):toBe(1)
		Expect(derived:Await()):toBe("kept")
	end)

	it("runs Finally on failure and preserves the rejection", function()
		local promise = Promise.new()
		local finallyCalls = 0
		promise:Finally(function()
			finallyCalls = finallyCalls + 1
		end)
		promise:Reject("lost")
		Expect(finallyCalls):toBe(1)
	end)

	it("times out Await when a timeout is provided", function()
		local promise = Promise.new()
		task.delay(0.1, function()
			promise:Resolve("too late")
		end)
		local ok = pcall(function()
			promise:Await(0.02)
		end)
		Expect(ok):toBeFalsy()
		Expect(promise:GetStatus()):toBe("Pending")
	end)

	it("constructs resolved and rejected promises directly", function()
		Expect(Promise.resolve(3):Await()):toBe(3)
		local ok = pcall(function()
			Promise.reject("nope"):Await()
		end)
		Expect(ok):toBeFalsy()
	end)
end)
