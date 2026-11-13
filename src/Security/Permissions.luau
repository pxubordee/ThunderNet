--!strict
-- Small permission helpers for event-level authorization.

local Permissions = {}

export type PermissionFunction = (player: any, data: any) -> (boolean, string?)

function Permissions.AllowAll(_player: any, _data: any): (boolean, string?)
	return true, nil
end

function Permissions.DenyAll(_player: any, _data: any): (boolean, string?)
	return false, "PERMISSION_DENIED"
end

function Permissions.UserIds(userIds: { number }): PermissionFunction
	local allowed: { [number]: boolean } = {}
	for _, userId in ipairs(userIds) do
		if type(userId) ~= "number" then
			error("Permissions.UserIds expects number user ids", 2)
		end
		allowed[userId] = true
	end
	return function(player: any, _data: any): (boolean, string?)
		if player ~= nil and allowed[player.UserId] == true then
			return true, nil
		end
		return false, "PERMISSION_DENIED"
	end
end

function Permissions.GroupRank(groupId: number, minimumRank: number): PermissionFunction
	if type(groupId) ~= "number" or type(minimumRank) ~= "number" then
		error("Permissions.GroupRank expects numeric groupId and minimumRank", 2)
	end
	return function(player: any, _data: any): (boolean, string?)
		local ok, rank = pcall(function()
			return player:GetRankInGroup(groupId)
		end)
		if ok and type(rank) == "number" and rank >= minimumRank then
			return true, nil
		end
		return false, "PERMISSION_DENIED"
	end
end

function Permissions.HasAttribute(attributeName: string, expected: any): PermissionFunction
	if type(attributeName) ~= "string" or #attributeName == 0 then
		error("Permissions.HasAttribute expects a non-empty attribute name", 2)
	end
	return function(player: any, _data: any): (boolean, string?)
		local ok, value = pcall(function()
			return player:GetAttribute(attributeName)
		end)
		if not ok then
			return false, "PERMISSION_DENIED"
		end
		if expected == nil then
			if value then
				return true, nil
			end
			return false, "PERMISSION_DENIED"
		end
		if value == expected then
			return true, nil
		end
		return false, "PERMISSION_DENIED"
	end
end

function Permissions.Custom(check: PermissionFunction): PermissionFunction
	if type(check) ~= "function" then
		error("Permissions.Custom expects a function", 2)
	end
	return check
end

function Permissions.Compose(...: PermissionFunction): PermissionFunction
	local checks = { ... }
	return function(player: any, data: any): (boolean, string?)
		for _, check in ipairs(checks) do
			local allowed, reason = check(player, data)
			if not allowed then
				return false, reason or "PERMISSION_DENIED"
			end
		end
		return true, nil
	end
end

return Permissions
