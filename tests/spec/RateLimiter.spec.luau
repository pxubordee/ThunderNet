--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local RateLimiter = require(ThunderNetFolder.Security.RateLimiter)

local describe, it = TestHarness.describe, TestHarness.it

describe("RateLimiter", function()
	it("allows up to the burst then refills over time", function()
		local limiter = RateLimiter.new({ DefaultRate = 2, DefaultBurst = 2 })
		local player = { UserId = 1 }
		Expect(limiter:Allow(player, nil, nil, nil, 0)):toBeTruthy()
		Expect(limiter:Allow(player, nil, nil, nil, 0)):toBeTruthy()
		local allowed, retryAfter = limiter:Allow(player, nil, nil, nil, 0)
		Expect(allowed):toBeFalsy()
		Expect(retryAfter):toBeNear(0.5)
		Expect(limiter:Allow(player, nil, nil, nil, 0.5)):toBeTruthy()
	end)

	it("caps refill at the burst size", function()
		local limiter = RateLimiter.new({ DefaultRate = 1, DefaultBurst = 3 })
		local player = { UserId = 2 }
		limiter:Allow(player, nil, nil, nil, 100)
		Expect(limiter:Allow(player, nil, nil, nil, 100)):toBeTruthy()
		Expect(limiter:Allow(player, nil, nil, nil, 100)):toBeTruthy()
		Expect(limiter:Allow(player, nil, nil, nil, 100)):toBeFalsy()
	end)

	it("keeps players and buckets isolated", function()
		local limiter = RateLimiter.new({ DefaultRate = 1, DefaultBurst = 1 })
		local alice = { UserId = 1 }
		local bob = { UserId = 2 }
		Expect(limiter:Allow(alice, nil, nil, nil, 0)):toBeTruthy()
		Expect(limiter:Allow(alice, nil, nil, nil, 0)):toBeFalsy()
		Expect(limiter:Allow(bob, nil, nil, nil, 0)):toBeTruthy()
		Expect(limiter:Allow(alice, "Combat", nil, nil, 0)):toBeTruthy()
		Expect(limiter:Allow(alice, "Combat", nil, nil, 0)):toBeFalsy()
	end)

	it("supports per-call rate and burst overrides", function()
		local limiter = RateLimiter.new({ DefaultRate = 10, DefaultBurst = 10 })
		local player = { UserId = 3 }
		Expect(limiter:Allow(player, "Combat", 1, 1, 0)):toBeTruthy()
		Expect(limiter:Allow(player, "Combat", 1, 1, 0)):toBeFalsy()
	end)

	it("removes player buckets on cleanup", function()
		local limiter = RateLimiter.new({ DefaultRate = 1, DefaultBurst = 1 })
		local player = { UserId = 4 }
		limiter:Allow(player, nil, nil, nil, 0)
		limiter:Allow(player, "Combat", nil, nil, 0)
		Expect(limiter:GetEntryCount()):toBe(2)
		limiter:RemovePlayer(player)
		Expect(limiter:GetEntryCount()):toBe(0)
		Expect(limiter:Allow(player, nil, nil, nil, 0)):toBeTruthy()
	end)

	it("rejects invalid construction and denies non-positive overrides", function()
		Expect(function()
			RateLimiter.new({ DefaultRate = 0, DefaultBurst = 1 })
		end):toThrow()
		local limiter = RateLimiter.new({ DefaultRate = 10, DefaultBurst = 10 })
		local allowed, retryAfter = limiter:Allow({ UserId = 5 }, nil, 0, 1, 0)
		Expect(allowed):toBeFalsy()
		Expect(retryAfter):toBe(math.huge)
	end)
end)
