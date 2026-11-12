--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Registry = require(ThunderNetFolder.Core.Registry)

local describe, it = TestHarness.describe, TestHarness.it

local function newRegistry()
	local calls = {}
	local registry = Registry.new("Server", function(destination, channel, data, priority, reliable)
		table.insert(calls, {
			Destination = destination,
			Channel = channel,
			Data = data,
			Priority = priority,
			Reliable = reliable,
		})
	end)
	return registry, calls
end

describe("Registry", function()
	it("creates events with defaults and returns stable handles", function()
		local registry, calls = newRegistry()
		local combat = registry:CreateEvent("Combat")
		Expect(combat.Name):toBe("Combat")
		Expect(combat:GetPriority()):toBe("Normal")
		Expect(registry:CreateEvent("Combat")):toBe(combat)
		Expect(registry:GetEvent("Combat")):toBe(combat)
		Expect(registry:GetEvent("Unknown")):toBeNil()
		Expect(registry:GetEvent("Combat"):IsUnreliable()):toBeFalsy()
		Expect(calls):toHaveLength(0)
		registry:Destroy()
	end)

	it("routes event sends through the transport hook", function()
		local registry, calls = newRegistry()
		local event = registry:CreateEvent("Combat", { Priority = "High", Unreliable = true })
		local player = { Name = "Alice", UserId = 1 }

		event:FireServer({ Damage = 1 })
		event:FireClient(player, { Damage = 2 })
		event:FireAll({ Damage = 3 })

		Expect(calls):toHaveLength(3)
		Expect(calls[1].Destination):toBe("Server")
		Expect(calls[1].Channel):toBe("Combat")
		Expect(calls[1].Priority):toBe(2)
		Expect(calls[1].Reliable):toBeFalsy()
		Expect(calls[2].Destination):toBe(player)
		Expect(calls[2].Data.Damage):toBe(2)
		Expect(calls[3].Destination):toBe("All")
		registry:Destroy()
	end)

	it("supports per-call priority overrides and rejects invalid priorities", function()
		local registry, calls = newRegistry()
		local event = registry:CreateEvent("Combat")
		event:FireServer({}, "Critical")
		Expect(calls[1].Priority):toBe(1)
		event:FireClient({}, {}, "Background")
		Expect(calls[2].Priority):toBe(5)
		Expect(function()
			event:FireAll({}, "Urgent")
		end):toThrow()
		registry:Destroy()
	end)

	it("stores permissions per event", function()
		local registry = newRegistry()
		local event = registry:CreateEvent("Combat")
		local permission = function()
			return true
		end
		Expect(event:GetPermission()):toBeNil()
		event:SetPermission(permission)
		Expect(event:GetPermission()):toBe(permission)
		event:SetPermission(nil)
		Expect(event:GetPermission()):toBeNil()
		registry:Destroy()
	end)

	it("registers and removes request handlers with duplicate protection", function()
		local registry = newRegistry()
		local handler = function()
			return 1
		end
		registry:SetRequestHandler("Purchase", handler)
		Expect(registry:GetRequestHandler("Purchase")):toBe(handler)
		Expect(function()
			registry:SetRequestHandler("Purchase", handler)
		end):toThrow()
		registry:RemoveRequestHandler("Purchase")
		Expect(registry:GetRequestHandler("Purchase")):toBeNil()
		registry:Destroy()
	end)

	it("clears definitions and rejects sends after destruction", function()
		local registry = newRegistry()
		local event = registry:CreateEvent("Combat")
		registry:Destroy()
		Expect(registry:GetEvent("Combat")):toBeNil()
		Expect(function()
			event:FireServer({})
		end):toThrow()
		Expect(function()
			registry:CreateEvent("Other")
		end):toThrow()
	end)
end)
