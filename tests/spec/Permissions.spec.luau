--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Permissions = require(ThunderNetFolder.Security.Permissions)

local describe, it = TestHarness.describe, TestHarness.it

describe("Permissions", function()
	it("allows or denies everyone", function()
		local player = { UserId = 1 }
		Expect(Permissions.AllowAll(player, nil)):toBeTruthy()
		local allowed, message = Permissions.DenyAll(player, nil)
		Expect(allowed):toBeFalsy()
		Expect(message):toBe("PERMISSION_DENIED")
	end)

	it("restricts by user id list", function()
		local check = Permissions.UserIds({ 10, 20 })
		Expect(check({ UserId = 10 }, nil)):toBeTruthy()
		Expect(check({ UserId = 11 }, nil)):toBeFalsy()
		Expect(check({ UserId = 20 }, nil)):toBeTruthy()
		local allowed, message = check({ UserId = 99 }, nil)
		Expect(allowed):toBeFalsy()
		Expect(message):toBe("PERMISSION_DENIED")
	end)

	it("combines checks in order and returns the first failure", function()
		local calls = {}
		local first = function()
			table.insert(calls, "first")
			return true
		end
		local second = function()
			table.insert(calls, "second")
			return false, "NO_SECOND"
		end
		local third = function()
			table.insert(calls, "third")
			return true
		end
		local check = Permissions.Compose(first, second, third)
		local allowed, message = check({ UserId = 1 }, nil)
		Expect(allowed):toBeFalsy()
		Expect(message):toBe("NO_SECOND")
		Expect(calls):toEqual({ "first", "second" })
	end)
end)
