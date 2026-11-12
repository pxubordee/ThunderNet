--!strict
-- Named channel: a grouping of events that share default options. Full event
-- names are "Channel/Event".

local Registry = require(script.Parent.Parent.Core.Registry)

local Channels = {}
Channels.__index = Channels

type State = {
	_host: any,
	_name: string,
	_defaults: any,
}

export type Channel = State & {
	GetName: (self: Channel) -> string,
	CreateEvent: <T>(self: Channel, localName: string, options: any?) -> Registry.TypedEvent<T>,
	GetEvent: <T>(self: Channel, localName: string, options: any?) -> Registry.TypedEvent<T>,
}

local function mergeOptions(defaults: any, options: any?): any
	local merged = {}
	for key, value in pairs(defaults) do
		merged[key] = value
	end
	if options then
		for key, value in pairs(options) do
			merged[key] = value
		end
	end
	return merged
end

function Channels.new(host: any, name: string, defaults: any?): Channel
	if type(name) ~= "string" or #name == 0 or #name > 64 then
		error("Channel name must be a non-empty string up to 64 characters", 3)
	end
	local self: Channel = setmetatable({
		_host = host,
		_name = name,
		_defaults = defaults or {},
	}, Channels) :: any
	return self
end

local function getName(self: Channel): string
	return self._name
end
Channels.GetName = getName

local function createEvent<T>(self: Channel, localName: string, options: any?): Registry.TypedEvent<T>
	return self._host:CreateEvent(self._name .. "/" .. localName, mergeOptions(self._defaults, options))
end
Channels.CreateEvent = createEvent

local function getEvent<T>(self: Channel, localName: string, options: any?): Registry.TypedEvent<T>
	return self._host:GetEvent(self._name .. "/" .. localName, mergeOptions(self._defaults, options))
end
Channels.GetEvent = getEvent

return Channels
