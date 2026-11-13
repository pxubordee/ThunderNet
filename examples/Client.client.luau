--!strict
-- ThunderNet For Roblox (ThunderNetworking) client example. Place under StarterPlayerScripts with
-- ReplicatedStorage.ThunderNet synced by Rojo.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ThunderNet = require(ReplicatedStorage:WaitForChild("ThunderNet"))

type CombatData = {
	Damage: number,
	TargetName: string,
}

type PositionData = {
	Position: Vector3,
}

type PurchaseRequest = {
	ItemId: number,
}

type PurchaseResult = {
	Success: boolean,
	PlayerName: string,
	ItemId: number,
}

local Net = ThunderNet.Client({ Name = "ThunderNetExample" })

local Hit = assert(Net:GetEvent("Combat/Hit")) :: ThunderNet.TypedEvent<CombatData>
local Movement = assert(Net:GetEvent("Movement")) :: ThunderNet.TypedEvent<PositionData>

Hit.OnClientEvent:Connect(function(data)
	print(("Combat result: %d damage to %s"):format(data.Damage, data.TargetName))
end)

Movement.OnClientEvent:Connect(function(data)
	-- Apply transient visuals here; never write authoritative state from this.
	local _position = data.Position
end)

Net:Use(function(context, next)
	-- Client-side middleware can log, mutate or reject inbound messages.
	return next(context)
end)

local function swing(targetName: string)
	Hit:FireServer({ Damage = 25, TargetName = targetName })
end

swing("Dummy")

local purchase: ThunderNet.PromiseOf<PurchaseResult> =
	Net:InvokeServer("Purchase", { ItemId = 7 } :: PurchaseRequest)
purchase:AndThen(function(result)
	print(("Purchased item %d for %s"):format(result.ItemId, result.PlayerName))
end)
purchase:Catch(function(err)
	warn("Purchase failed: " .. tostring(err))
end)

-- Unreliable high-frequency input can be sent the same way:
-- Movement:FireServer({ Position = Vector3.new(0, 0, 0) })
