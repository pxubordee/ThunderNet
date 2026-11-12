--!strict
-- Unreliable transport for transient, high-frequency data. Backed by
-- UnreliableRemoteEvent; never use it for critical state changes.

local Unreliable = {}
Unreliable.__index = Unreliable

type State = {
	Instance: any,
	IsReliable: boolean,
}

export type Transport = typeof(setmetatable({} :: State, Unreliable))

function Unreliable.new(instance: any): Transport
	return setmetatable({
		Instance = instance,
		IsReliable = false,
	}, Unreliable)
end

function Unreliable:GetInstance(): any
	return self.Instance
end

function Unreliable:FireClient(player: any, packet: any)
	self.Instance:FireClient(player, packet)
end

function Unreliable:FireServer(packet: any)
	self.Instance:FireServer(packet)
end

function Unreliable:FireAllClients(packet: any)
	self.Instance:FireAllClients(packet)
end

return Unreliable
