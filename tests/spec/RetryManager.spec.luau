--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local RetryManager = require(ThunderNetFolder.Features.RetryManager)

local describe, it = TestHarness.describe, TestHarness.it

describe("RetryManager", function()
	it("enforces retry budgets", function()
		local retries = RetryManager.new({ MaxAttempts = 3 })
		Expect(retries:ShouldRetry(1)):toBeTruthy()
		Expect(retries:ShouldRetry(2)):toBeTruthy()
		Expect(retries:ShouldRetry(3)):toBeFalsy()
		Expect(retries:ShouldRetry(4)):toBeFalsy()
		Expect(retries:GetMaxAttempts()):toBe(3)
	end)

	it("computes exponential backoff without jitter", function()
		local retries = RetryManager.new({
			MaxAttempts = 5,
			BaseDelay = 0.5,
			MaxDelay = 4,
			Jitter = 0,
			Random = function()
				return 0.5
			end,
		})
		Expect(retries:NextDelay(1)):toBeNear(0.5)
		Expect(retries:NextDelay(2)):toBeNear(1)
		Expect(retries:NextDelay(3)):toBeNear(2)
		Expect(retries:NextDelay(4)):toBeNear(4)
		Expect(retries:NextDelay(10)):toBeNear(4)
	end)

	it("applies bounded jitter", function()
		local low = RetryManager.new({
			BaseDelay = 1,
			Jitter = 0.25,
			Random = function()
				return 0
			end,
		})
		local high = RetryManager.new({
			BaseDelay = 1,
			Jitter = 0.25,
			Random = function()
				return 1
			end,
		})
		local middle = RetryManager.new({
			BaseDelay = 1,
			Jitter = 0.25,
			Random = function()
				return 0.5
			end,
		})
		Expect(low:NextDelay(1)):toBeNear(0.75)
		Expect(high:NextDelay(1)):toBeNear(1.25)
		Expect(middle:NextDelay(1)):toBeNear(1)
	end)

	it("rejects invalid configuration", function()
		Expect(function()
			RetryManager.new({ MaxAttempts = 0 })
		end):toThrow()
		Expect(function()
			RetryManager.new({ BaseDelay = -1 })
		end):toThrow()
		Expect(function()
			RetryManager.new({ Jitter = 2 })
		end):toThrow()
	end)
end)
