--!strict
-- ThunderNet entry point.
--
--   local ThunderNet = require(ReplicatedStorage.ThunderNet)
--   local Net = ThunderNet.Server()  -- or ThunderNet.Client()

local Network = require(script.Core.Network)
local Types = require(script.Types.Types)
local Signal = require(script.Utilities.Signal)
local Promise = require(script.Utilities.Promise)
local Janitor = require(script.Utilities.Janitor)
local Validator = require(script.Security.Validator)
local Permissions = require(script.Security.Permissions)

export type Network = Network.Network
export type NetworkConfig = Types.NetworkConfig
export type NetworkStats = Types.NetworkStats
export type Event = Network.Event
export type TypedEvent<T = any> = Network.TypedEvent<T>
export type PromiseOf<T = any> = Promise.PromiseOf<T>
export type EventOptions = Network.EventOptions
export type Timer = Network.Timer

local ThunderNet = {
	Priority = table.freeze({
		Critical = "Critical",
		High = "High",
		Normal = "Normal",
		Low = "Low",
		Background = "Background",
	}),
	Signal = Signal,
	Promise = Promise,
	Janitor = Janitor,
	Validator = Validator,
	Permissions = Permissions,
	Types = Types,
}

function ThunderNet.Server(config: Types.NetworkConfig?): Network.Network
	return Network.new("Server", config)
end

function ThunderNet.Client(config: Types.NetworkConfig?): Network.Network
	return Network.new("Client", config)
end

return ThunderNet
