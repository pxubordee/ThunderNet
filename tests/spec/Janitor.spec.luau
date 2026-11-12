--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Janitor = require(ThunderNetFolder.Utilities.Janitor)

local describe, it = TestHarness.describe, TestHarness.it

local function makeConnection()
	local connection = {
		Connected = true,
	}
	function connection:Disconnect()
		self.Connected = false
	end
	return connection
end

describe("Janitor", function()
	it("cleans functions, connections, instances and destroyable tables", function()
		local janitor = Janitor.new()
		local calls = {}

		janitor:Add(function()
			table.insert(calls, "function")
		end)

		local connection = makeConnection()
		janitor:Add(connection)
		Expect(janitor:GetCount()):toBe(2)

		local instance = game:GetService("ReplicatedStorage")
		local folder = Instance.new("Folder")
		folder.Parent = instance
		janitor:Add(folder)

		local destroyable = {}
		function destroyable:Destroy()
			table.insert(calls, "destroyable")
		end
		janitor:Add(destroyable)

		janitor:Cleanup()
		Expect(calls):toContain("function")
		Expect(calls):toContain("destroyable")
		Expect(connection.Connected):toBeFalsy()
		Expect(folder.Parent):toBeNil()
		Expect(janitor:GetCount()):toBe(0)
	end)

	it("cleans in reverse insertion order", function()
		local janitor = Janitor.new()
		local order = {}
		janitor:Add(function()
			table.insert(order, 1)
		end)
		janitor:Add(function()
			table.insert(order, 2)
		end)
		janitor:Add(function()
			table.insert(order, 3)
		end)
		janitor:Cleanup()
		Expect(order):toEqual({ 3, 2, 1 })
	end)

	it("removes an item without cleaning it", function()
		local janitor = Janitor.new()
		local calls = 0
		local item = function()
			calls = calls + 1
		end
		janitor:Add(item)
		janitor:Remove(item)
		janitor:Cleanup()
		Expect(calls):toBe(0)
	end)

	it("rejects additions after destruction and is idempotent", function()
		local janitor = Janitor.new()
		local calls = 0
		janitor:Add(function()
			calls = calls + 1
		end)
		janitor:Destroy()
		janitor:Destroy()
		Expect(calls):toBe(1)
		Expect(function()
			janitor:Add(function() end)
		end):toThrow()
	end)

	it("supports linking nested janitors", function()
		local outer = Janitor.new()
		local inner = Janitor.new()
		outer:Add(inner)
		local calls = 0
		inner:Add(function()
			calls = calls + 1
		end)
		outer:Cleanup()
		Expect(calls):toBe(1)
	end)

	it("cleans individual items with Remove on cleanup key", function()
		local janitor = Janitor.new()
		local calls = 0
		local key = janitor:Add(function()
			calls = calls + 1
		end)
		janitor:Remove(key)
		janitor:Cleanup()
		Expect(calls):toBe(0)
	end)
end)
