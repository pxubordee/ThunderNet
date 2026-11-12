--!strict
-- Lightweight event signal with allocation-free emission and safe
-- disconnection during dispatch.

local Signal = {}
Signal.__index = Signal

export type Handler = (...any) -> ()
export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

type InternalConnection = Connection & {
	_handler: Handler?,
}

type State = {
	_connections: { InternalConnection },
	_count: number,
	_highestIndex: number,
	_destroyed: boolean,
}

export type Signal = State & {
	Connect: (self: Signal, handler: Handler) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	DisconnectAll: (self: Signal) -> (),
	GetConnectionCount: (self: Signal) -> number,
	Destroy: (self: Signal) -> (),
}

function Signal.new(): Signal
	local self: Signal = setmetatable({
		_connections = {} :: { InternalConnection },
		_count = 0,
		_highestIndex = 0,
		_destroyed = false,
	}, Signal) :: any
	return self
end

local function compact(self: Signal)
	if self._highestIndex <= self._count * 2 + 8 then
		return
	end
	local connections: { InternalConnection } = (table.create(self._count) :: any)
	local writeIndex = 0
	for index = 1, self._highestIndex do
		local connection = self._connections[index]
		if connection and connection.Connected then
			writeIndex += 1
			connections[writeIndex] = connection
		end
	end
	self._connections = connections
	self._highestIndex = writeIndex
end

local function connect(self: Signal, handler: Handler): Connection
	if self._destroyed then
		error("Signal is destroyed", 2)
	end
	if type(handler) ~= "function" then
		error("Signal handler must be a function", 2)
	end

	local state = self
	local connection: InternalConnection = {
		Connected = true,
		_handler = handler,
		Disconnect = function(conn: Connection)
			if not conn.Connected then
				return
			end
			conn.Connected = false
			local internal = conn :: InternalConnection
			internal._handler = nil
			state._count -= 1
		end,
	}

	self._count += 1
	self._highestIndex += 1
	self._connections[self._highestIndex] = connection
	return connection
end
Signal.Connect = connect

local function fire(self: Signal, ...: any)
	if self._destroyed then
		error("Signal is destroyed", 2)
	end
	compact(self)
	local connections = self._connections
	local highest = self._highestIndex
	for index = 1, highest do
		local connection = connections[index]
		if connection and connection.Connected then
			local handler = connection._handler
			if handler then
				handler(...)
			end
		end
	end
end
Signal.Fire = fire

local function disconnectAll(self: Signal)
	local connections = self._connections
	for index = 1, self._highestIndex do
		local connection = connections[index]
		if connection then
			connection.Connected = false
			connection._handler = nil
		end
	end
	self._connections = {}
	self._count = 0
	self._highestIndex = 0
end
Signal.DisconnectAll = disconnectAll

local function getConnectionCount(self: Signal): number
	return self._count
end
Signal.GetConnectionCount = getConnectionCount

local function destroy(self: Signal)
	if self._destroyed then
		return
	end
	disconnectAll(self)
	self._destroyed = true
end
Signal.Destroy = destroy

return Signal
