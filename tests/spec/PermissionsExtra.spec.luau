--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Permissions = require(ThunderNetFolder.Security.Permissions)

local describe, it = TestHarness.describe, TestHarness.it

local function playerWith(rank, attributes)
	local player = {
		UserId = 1,
		attributes = attributes or {},
	}
	function player:GetRankInGroup(groupId)
		return rank
	end
	function player:GetAttribute(name)
		return self.attributes[name]
	end
	return player
end

describe("Permissions helpers", function()
	it("checks group rank", function()
		local check = Permissions.GroupRank(123, 50)
		Expect(check(playerWith(50), nil)):toBeTruthy()
		Expect(check(playerWith(75), nil)):toBeTruthy()
		local allowed, message = check(playerWith(49), nil)
		Expect(allowed):toBeFalsy()
		Expect(message):toBe("PERMISSION_DENIED")
	end)

	it("checks attributes with an optional expected value", function()
		local truthy = Permissions.HasAttribute("Admin")
		Expect(truthy(playerWith(0, { Admin = true }), nil)):toBeTruthy()
		Expect(truthy(playerWith(0, { Admin = false }), nil)):toBeFalsy()

		local exact = Permissions.HasAttribute("Tier", 3)
		Expect(exact(playerWith(0, { Tier = 3 }), nil)):toBeTruthy()
		Expect(exact(playerWith(0, { Tier = 2 }), nil)):toBeFalsy()
	end)
end)
