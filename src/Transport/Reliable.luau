--!strict
-- Reliable transport: a thin wrapper over a RemoteEvent instance.

local Reliable = {}
Reliable.__index = Reliable

type State = {
	Instance: any,
	IsReliable: boolean,
}

export type Transport = typeof(setmetatable({} :: State, Reliable))

function Reliable.new(instance: any): Transport
	return setmetatable({
		Instance = instance,
		IsReliable = true,
	}, Reliable)
end

function Reliable:GetInstance(): any
	return self.Instance
end

function Reliable:FireClient(player: any, packet: any)
	self.Instance:FireClient(player, packet)
end

function Reliable:FireServer(packet: any)
	self.Instance:FireServer(packet)
end

function Reliable:FireAllClients(packet: any)
	self.Instance:FireAllClients(packet)
end

return Reliable
