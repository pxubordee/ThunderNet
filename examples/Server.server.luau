--!strict
-- ThunderNet For Roblox (ThunderNetworking) server example. Place under ServerScriptService with
-- ReplicatedStorage.ThunderNet synced by Rojo.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ThunderNet = require(ReplicatedStorage:WaitForChild("ThunderNet"))

type CombatData = {
	Damage: number,
	TargetName: string,
}

type PositionData = {
	Position: Vector3,
}

local Net = ThunderNet.Server({
	Name = "ThunderNetExample",
	Stats = true,
	RateLimit = { Rate = 60, Burst = 120 },
	Payload = { MaxBytes = 4096, MaxDepth = 6 },
	Batch = {
		MaxBatchSize = 64,
		MaxBatchBytes = 16000,
		FlushInterval = 0,
		Adaptive = true,
		MaxLatency = 0.05,
		AdaptiveDepthThreshold = 32,
	},
	Request = { Timeout = 4, MaxAttempts = 3, DedupeTtl = 30 },
})

local Combat = Net:CreateChannel("Combat", { Priority = "High" })

local Hit = Combat:CreateEvent("Hit", {
	Schema = ThunderNet.Validator.Table({
		Fields = {
			Damage = ThunderNet.Validator.Number({ Min = 0, Max = 100 }),
			TargetName = ThunderNet.Validator.String({ MaxLength = 32 }),
		},
	}),
}) :: ThunderNet.TypedEvent<CombatData>

local Movement = Net:CreateEvent("Movement", {
	Unreliable = true,
	Priority = "Low",
}) :: ThunderNet.TypedEvent<PositionData>

-- Middleware runs before every inbound event/request on this session.
Net:Use(function(context, next)
	if context.Kind == "Event" and context.Channel == "Combat/Hit" then
		-- Example hook: reject if the sender is not in an allowlist, mutate
		-- context.Data, or throw a { Code, Message } error table.
	end
	return next(context)
end)

Hit.OnServerEvent:Connect(function(player, data)
	-- Never trust client-supplied damage or targets. Clamp and re-derive the
	-- authoritative result using server state before broadcasting.
	local authoritativeDamage = math.clamp(data.Damage, 0, 10)
	print(("%s hit %s for %d (server authoritative)"):format(player.Name, data.TargetName, authoritativeDamage))
	Hit:FireAll({
		Damage = authoritativeDamage,
		TargetName = data.TargetName,
	})
end)

Movement.OnServerEvent:Connect(function(_player, _data)
	-- Unreliable lane: transient cosmetic state only. Never drive gameplay
	-- state changes from this lane.
end)

Net:OnRequest("Purchase", function(player, request)
	-- Validate price/ownership against server state before granting anything.
	return {
		Success = true,
		PlayerName = player.Name,
		ItemId = request.ItemId,
	}
end)

-- High-frequency cosmetic snapshots over the unreliable lane.
task.spawn(function()
	while true do
		task.wait(0.1)
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			local position = if character then character:GetPivot().Position else Vector3.new(0, 0, 0)
			Movement:FireClient(player, { Position = position })
		end
	end
end)
