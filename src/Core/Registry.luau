--!strict
-- Registry of event definitions and request handlers. Event handles own their
-- signals and forward outbound fires to the network through a send hook, which
-- keeps this module free of transport and batching concerns.

local Signal = require(script.Parent.Parent.Utilities.Signal)

local Registry = {}
Registry.__index = Registry

export type Side = "Server" | "Client"

export type PriorityName = "Critical" | "High" | "Normal" | "Low" | "Background"

export type EventOptions = {
	Unreliable: boolean?,
	Priority: PriorityName?,
	Permission: ((player: any, data: any) -> (boolean, string?))?,
	Schema: any?,
	Validate: ((data: any) -> (boolean, string?))?,
	RateLimit: { Rate: number, Burst: number }?,
}

export type SendHook = (
	destination: any,
	channel: string,
	data: any,
	priority: number,
	reliable: boolean
) -> ()

export type RequestHandler = (player: any, data: any) -> any

export type Permission = (player: any, data: any) -> (boolean, string?)

local priorityLevels: { [string]: number } = {
	Critical = 1,
	High = 2,
	Normal = 3,
	Low = 4,
	Background = 5,
}
Registry.PriorityLevels = table.freeze(priorityLevels)

function Registry.GetPriorityLevel(name: string): number?
	return priorityLevels[name]
end

local EventClass = {}
EventClass.__index = EventClass

type EventState = {
	Name: string,
	_Options: EventOptions,
	_Priority: PriorityName,
	_Unreliable: boolean,
	_Permission: Permission?,
	_Registry: any,
	OnServerEvent: Signal.Signal,
	OnClientEvent: Signal.Signal,
}

export type Event = EventState & {
	FireServer: (self: Event, data: any, priority: PriorityName?) -> (),
	FireClient: (self: Event, player: any, data: any, priority: PriorityName?) -> (),
	FireAll: (self: Event, data: any, priority: PriorityName?) -> (),
	SetPriority: (self: Event, priority: PriorityName) -> (),
	GetPriority: (self: Event) -> PriorityName,
	IsUnreliable: (self: Event) -> boolean,
	SetPermission: (self: Event, permission: Permission?) -> (),
	GetPermission: (self: Event) -> Permission?,
	GetOptions: (self: Event) -> EventOptions,
}

export type TypedEvent<T = any> = {
	Name: string,
	OnServerEvent: Signal.Signal,
	OnClientEvent: Signal.Signal,
	FireServer: (self: TypedEvent<T>, data: T, priority: PriorityName?) -> (),
	FireClient: (self: TypedEvent<T>, player: any, data: T, priority: PriorityName?) -> (),
	FireAll: (self: TypedEvent<T>, data: T, priority: PriorityName?) -> (),
	SetPriority: (self: TypedEvent<T>, priority: PriorityName) -> (),
	GetPriority: (self: TypedEvent<T>) -> PriorityName,
	IsUnreliable: (self: TypedEvent<T>) -> boolean,
	SetPermission: (self: TypedEvent<T>, permission: Permission?) -> (),
	GetPermission: (self: TypedEvent<T>) -> Permission?,
	GetOptions: (self: TypedEvent<T>) -> EventOptions,
}

type State = {
	_side: Side,
	_events: { [string]: Event },
	_requestHandlers: { [string]: RequestHandler },
	_sendHook: SendHook,
	_destroyed: boolean,
}

export type Registry = State & {
	CreateEvent: (self: Registry, name: string, options: EventOptions?) -> Event,
	GetEvent: (self: Registry, name: string) -> Event?,
	GetDefinition: (self: Registry, name: string) -> Event?,
	SetRequestHandler: (self: Registry, name: string, handler: RequestHandler) -> (),
	GetRequestHandler: (self: Registry, name: string) -> RequestHandler?,
	RemoveRequestHandler: (self: Registry, name: string) -> boolean,
	GetSide: (self: Registry) -> Side,
	Destroy: (self: Registry) -> (),
}

local function getLevel(name: PriorityName): number
	local level = priorityLevels[name]
	if not level then
		error(("Invalid priority %q"):format(tostring(name)), 3)
	end
	return level
end

local function send(event: Event, destination: any, data: any, priority: PriorityName?)
	local registry = event._Registry :: Registry
	if registry._destroyed then
		error("Registry is destroyed", 3)
	end
	local priorityName = priority or event._Priority
	local level = getLevel(priorityName)
	registry._sendHook(destination, event.Name, data, level, not event._Unreliable)
end

local function fireServer(self: Event, data: any, priority: PriorityName?)
	send(self, "Server", data, priority)
end
EventClass.FireServer = fireServer

local function fireClient(self: Event, player: any, data: any, priority: PriorityName?)
	if player == nil then
		error("FireClient requires a player", 3)
	end
	send(self, player, data, priority)
end
EventClass.FireClient = fireClient

local function fireAll(self: Event, data: any, priority: PriorityName?)
	send(self, "All", data, priority)
end
EventClass.FireAll = fireAll

local function setPriority(self: Event, priority: PriorityName)
	getLevel(priority)
	self._Priority = priority
	self._Options.Priority = priority
end
EventClass.SetPriority = setPriority

local function getPriority(self: Event): PriorityName
	return self._Priority
end
EventClass.GetPriority = getPriority

local function isUnreliable(self: Event): boolean
	return self._Unreliable
end
EventClass.IsUnreliable = isUnreliable

local function setPermission(self: Event, permission: Permission?)
	if permission ~= nil and type(permission) ~= "function" then
		error("Permission must be a function or nil", 3)
	end
	self._Permission = permission
end
EventClass.SetPermission = setPermission

local function getPermission(self: Event): Permission?
	return self._Permission
end
EventClass.GetPermission = getPermission

local function getOptions(self: Event): EventOptions
	return self._Options
end
EventClass.GetOptions = getOptions

function Registry.new(side: Side, sendHook: SendHook): Registry
	local self: Registry = setmetatable({
		_side = side,
		_events = {} :: { [string]: Event },
		_requestHandlers = {} :: { [string]: RequestHandler },
		_sendHook = sendHook,
		_destroyed = false,
	}, Registry) :: any
	return self
end

local function assertName(name: any)
	if type(name) ~= "string" or #name == 0 or #name > 128 then
		error("Event name must be a non-empty string up to 128 characters", 4)
	end
end

local function normalizeOptions(options: EventOptions?): EventOptions
	local normalized: any = {}
	if options then
		for key, value in pairs(options :: any) do
			normalized[key] = value
		end
	end
	if normalized.Priority == nil then
		normalized.Priority = "Normal"
	end
	getLevel(normalized.Priority :: PriorityName)
	if normalized.Unreliable == nil then
		normalized.Unreliable = false
	end
	return normalized :: EventOptions
end

local function createEvent(self: Registry, name: string, options: EventOptions?): Event
	if self._destroyed then
		error("Registry is destroyed", 3)
	end
	assertName(name)
	local existing = self._events[name]
	if existing then
		return existing
	end
	local normalized = normalizeOptions(options)
	local event: Event = setmetatable({
		Name = name,
		_Options = normalized,
		_Priority = normalized.Priority :: PriorityName,
		_Unreliable = normalized.Unreliable == true,
		_Permission = normalized.Permission,
		_Registry = self,
		OnServerEvent = Signal.new(),
		OnClientEvent = Signal.new(),
	}, EventClass) :: any
	self._events[name] = event
	return event
end
Registry.CreateEvent = createEvent

local function getEvent(self: Registry, name: string): Event?
	return self._events[name]
end
Registry.GetEvent = getEvent
Registry.GetDefinition = getEvent

local function setRequestHandler(self: Registry, name: string, handler: RequestHandler)
	if self._destroyed then
		error("Registry is destroyed", 3)
	end
	assertName(name)
	if type(handler) ~= "function" then
		error("Request handler must be a function", 3)
	end
	if self._requestHandlers[name] ~= nil then
		error(("A request handler for %q is already registered"):format(name), 3)
	end
	self._requestHandlers[name] = handler
end
Registry.SetRequestHandler = setRequestHandler

local function getRequestHandler(self: Registry, name: string): RequestHandler?
	return self._requestHandlers[name]
end
Registry.GetRequestHandler = getRequestHandler

local function removeRequestHandler(self: Registry, name: string): boolean
	if self._requestHandlers[name] == nil then
		return false
	end
	self._requestHandlers[name] = nil
	return true
end
Registry.RemoveRequestHandler = removeRequestHandler

local function getSide(self: Registry): Side
	return self._side
end
Registry.GetSide = getSide

local function destroy(self: Registry)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, event in pairs(self._events) do
		event.OnServerEvent:Destroy()
		event.OnClientEvent:Destroy()
	end
	self._events = {}
	self._requestHandlers = {}
end
Registry.Destroy = destroy

return Registry
