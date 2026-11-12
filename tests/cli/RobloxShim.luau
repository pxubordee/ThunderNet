--!nocheck
-- Minimal Roblox API simulation used by the Luau CLI test runner.
-- This file is test infrastructure only; it is never shipped to Roblox.

local nativeTypeof = typeof

local RobloxShim = {}

local function newSignal()
	local listeners = {}
	local connections = {}
	local order = {}
	local signal = {}

	function signal:Connect(handler)
		local connection = { Connected = true }
		function connection:Disconnect()
			if not self.Connected then
				return
			end
			self.Connected = false
			listeners[self] = nil
		end
		listeners[connection] = handler
		table.insert(order, connection)
		return connection
	end

	function signal:Fire(...)
		local count = #order
		for index = 1, count do
			local connection = order[index]
			if connection.Connected then
				local handler = listeners[connection]
				if handler then
					handler(...)
				end
			end
		end
		if #order > 64 then
			local kept = {}
			for _, connection in ipairs(order) do
				if connection.Connected then
					table.insert(kept, connection)
				end
			end
			order = kept
		end
	end

	function signal:DisconnectAll()
		for connection in pairs(listeners) do
			connection.Connected = false
		end
		listeners = {}
		order = {}
	end

	return signal
end

RobloxShim.newSignal = newSignal

local parentClass = {
	Instance = nil,
	DataModel = "Instance",
	Folder = "Instance",
	ModuleScript = "Instance",
	Script = "Instance",
	RemoteEvent = "Instance",
	UnreliableRemoteEvent = "Instance",
	Player = "Instance",
	Model = "Instance",
	Part = "Instance",
	Value = "Instance",
	StringValue = "Value",
}

local function buildClassMethods(parentMethods, own)
	local methods = setmetatable({}, { __index = parentMethods })
	for key, value in pairs(own) do
		methods[key] = value
	end
	return methods
end

local instanceMethods = {}

function instanceMethods:FindFirstChild(name)
	return self._children[name]
end

function instanceMethods:GetChildren()
	local children = {}
	for _, child in ipairs(self._childrenList) do
		if child.Parent == self then
			table.insert(children, child)
		end
	end
	return children
end

function instanceMethods:GetDescendants()
	local descendants = {}
	local stack = { self }
	while #stack > 0 do
		local current = table.remove(stack)
		for _, child in ipairs(current:GetChildren()) do
			table.insert(descendants, child)
			table.insert(stack, child)
		end
	end
	return descendants
end

function instanceMethods:IsA(className)
	local current = self.ClassName
	while current do
		if current == className then
			return true
		end
		current = parentClass[current]
	end
	return false
end

function instanceMethods:WaitForChild(name)
	local child = self._children[name]
	if not child then
		error(("%q is not a valid member of %s (shim has no streaming; create it first)"):format(name, self.Name), 2)
	end
	return self._shim._wrapForClient(child)
end

function instanceMethods:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, child in ipairs(self._childrenList) do
		child:Destroy()
	end
	self._childrenList = {}
	self._children = {}
	if self.Parent then
		self.Parent._children[self.Name] = nil
	end
	self.Parent = nil
end

local remoteMethods = buildClassMethods(instanceMethods, {
	FireAllClients = function(self, ...)
		for _, entry in pairs(self._clients) do
			entry.signal:Fire(...)
		end
	end,
	FireClient = function(self, player, ...)
		local entry = self._clients[player]
		if entry then
			entry.signal:Fire(...)
		end
	end,
	FireServer = function()
		error("FireServer can only be used from a client context", 2)
	end,
})

local classMethods = {
	Instance = instanceMethods,
	DataModel = instanceMethods,
	Folder = instanceMethods,
	ModuleScript = instanceMethods,
	Script = instanceMethods,
	Player = instanceMethods,
	Model = instanceMethods,
	Part = instanceMethods,
	Value = instanceMethods,
	StringValue = instanceMethods,
	RemoteEvent = remoteMethods,
	UnreliableRemoteEvent = remoteMethods,
}

local function makeDatatype(typeName, constructor)
	local class = {}
	class.__index = class
	class.new = constructor
	class.__tnTag = typeName
	return class
end

local Vector2 = makeDatatype("Vector2", function(x, y)
	return setmetatable({ __tnTag = "Vector2", X = x or 0, Y = y or 0 }, Vector2)
end)

local Vector3 = makeDatatype("Vector3", function(x, y, z)
	return setmetatable({ __tnTag = "Vector3", X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end)

local Color3 = makeDatatype("Color3", function(r, g, b)
	return setmetatable({ __tnTag = "Color3", R = r or 0, G = g or 0, B = b or 0 }, Color3)
end)

local UDim = makeDatatype("UDim", function(scale, offset)
	return setmetatable({ __tnTag = "UDim", Scale = scale or 0, Offset = offset or 0 }, UDim)
end)

local UDim2 = makeDatatype("UDim2", function(xScale, xOffset, yScale, yOffset)
	return setmetatable({
		__tnTag = "UDim2",
		X = UDim.new(xScale or 0, xOffset or 0),
		Y = UDim.new(yScale or 0, yOffset or 0),
		XScale = xScale or 0,
		XOffset = xOffset or 0,
		YScale = yScale or 0,
		YOffset = yOffset or 0,
	}, UDim2)
end)

local CFrame = makeDatatype("CFrame", function(...)
	local args = table.pack(...)
	if args.n == 3 then
		return setmetatable({
			__tnTag = "CFrame",
			X = args[1],
			Y = args[2],
			Z = args[3],
			R00 = 1, R01 = 0, R02 = 0,
			R10 = 0, R11 = 1, R12 = 0,
			R20 = 0, R21 = 0, R22 = 1,
		}, CFrame)
	elseif args.n == 12 then
		return setmetatable({
			__tnTag = "CFrame",
			X = args[1], Y = args[2], Z = args[3],
			R00 = args[4], R01 = args[5], R02 = args[6],
			R10 = args[7], R11 = args[8], R12 = args[9],
			R20 = args[10], R21 = args[11], R22 = args[12],
		}, CFrame)
	end
	error("shim CFrame.new supports 3 or 12 arguments", 2)
end)

function RobloxShim.new()
	local self = {}
	self.clock = 0
	self.errors = {}
	self._currentClient = nil
	self._threads = {}
	self._timers = {}
	self._deferred = {}
	self._playerCount = 0

	local deepEqual = function(a, b, seen)
		if a == b then
			return true
		end
		if type(a) ~= "table" or type(b) ~= "table" then
			return false
		end
		seen = seen or {}
		local key = tostring(a) .. "|" .. tostring(b)
		if seen[key] then
			return true
		end
		seen[key] = true
		for k, v in pairs(a) do
			if not deepEqual(v, b[k], seen) then
				return false
			end
		end
		for k in pairs(b) do
			if a[k] == nil then
				return false
			end
		end
		return true
	end

	local function attachParent(instance, parent)
		local current = rawget(instance, "Parent")
		if current then
			local siblings = rawget(current, "_children")
			if siblings and siblings[rawget(instance, "Name")] == instance then
				siblings[rawget(instance, "Name")] = nil
			end
			local list = rawget(current, "_childrenList")
			for index = #list, 1, -1 do
				if list[index] == instance then
					table.remove(list, index)
				end
			end
		end
		rawset(instance, "Parent", parent)
		if parent then
			local siblings = rawget(parent, "_children")
			siblings[rawget(instance, "Name")] = instance
			table.insert(rawget(parent, "_childrenList"), instance)
		end
	end

	local function newInstance(className, name)
		local methods = classMethods[className]
		if not methods then
			error(("shim does not implement class %q"):format(tostring(className)), 2)
		end
		local instance = {
			__tnTag = "Instance",
			ClassName = className,
			Name = name or className,
			Parent = nil,
			_children = {},
			_childrenList = {},
			_shim = self,
			_destroyed = false,
		}
		if className == "RemoteEvent" or className == "UnreliableRemoteEvent" then
			instance._serverSignal = newSignal()
			instance._clients = {}
			instance.OnServerEvent = instance._serverSignal
		end
		setmetatable(instance, {
			__index = function(target, key)
				local method = methods[key]
				if method ~= nil then
					return method
				end
				return rawget(target, "_children")[key]
			end,
			__newindex = function(target, key, value)
				if key == "Parent" then
					attachParent(target, value)
				else
					rawset(target, key, value)
				end
			end,
		})
		return instance
	end

	local instanceFactory = {}
	function instanceFactory.new(className, name)
		return newInstance(className, name)
	end
	self.Instance = instanceFactory

	local game = newInstance("DataModel", "Game")
	self.game = game

	local replicatedStorage = newInstance("Folder", "ReplicatedStorage")
	local serverScriptService = newInstance("Folder", "ServerScriptService")
	local playersService = newInstance("Folder", "Players")
	local runService = newInstance("Folder", "RunService")
	playersService.PlayerAdded = newSignal()
	playersService.PlayerRemoving = newSignal()
	playersService.LocalPlayer = nil
	function playersService:GetPlayers()
		return self:GetChildren()
	end
	runService.Heartbeat = newSignal()

	local services = {
		ReplicatedStorage = replicatedStorage,
		ServerScriptService = serverScriptService,
		Players = playersService,
		RunService = runService,
	}
	for _, service in pairs(services) do
		attachParent(service, game)
	end
	function game:GetService(name)
		local service = services[name]
		if not service then
			error(("'%s' is not a valid Service name (shim)"):format(tostring(name)), 2)
		end
		return service
	end

	function self._wrapForClient(child)
		if not self._currentClient then
			return child
		end
		if child.ClassName ~= "RemoteEvent" and child.ClassName ~= "UnreliableRemoteEvent" then
			return child
		end
		local entry = child._clients[self._currentClient]
		if not entry then
			entry = { signal = newSignal(), player = self._currentClient }
			child._clients[self._currentClient] = entry
		end
		local player = self._currentClient
		local view = {
			__tnTag = "Instance",
			ClassName = child.ClassName,
			Name = child.Name,
			Parent = child.Parent,
			OnClientEvent = entry.signal,
			_remote = child,
			_player = player,
		}
		function view:FireServer(...)
			child._serverSignal:Fire(player, ...)
		end
		return view
	end

	local function typeofValue(value)
		local raw = nativeTypeof(value)
		if raw == "table" then
			local tag = rawget(value, "__tnTag")
			if type(tag) == "string" then
				return tag
			end
		end
		return raw
	end
	self.typeof = typeofValue
	self.Vector2 = Vector2
	self.Vector3 = Vector3
	self.CFrame = CFrame
	self.Color3 = Color3
	self.UDim = UDim
	self.UDim2 = UDim2

	local fakeOs = {
		clock = function()
			return self.clock
		end,
		time = os.time,
		date = os.date,
		difftime = os.difftime,
	}
	self.os = fakeOs
	self.warn = function(...)
		local parts = { "[shim warn]" }
		for index = 1, select("#", ...) do
			table.insert(parts, tostring(select(index, ...)))
		end
		print(table.concat(parts, " "))
	end
	self.deepEqual = deepEqual

	local task = {}
	self.task = task

	local function resumeEntry(entry)
		if entry.dead or entry.cancelled then
			return
		end
		local args = entry.args
		entry.args = nil
		local results
		if args then
			results = table.pack(coroutine.resume(entry.co, table.unpack(args, 1, args.n)))
		else
			results = table.pack(coroutine.resume(entry.co))
		end
		if not results[1] then
			table.insert(self.errors, tostring(results[2]))
			entry.dead = true
			return
		end
		if coroutine.status(entry.co) == "dead" then
			entry.dead = true
		else
			local yielded = results[2]
			local waitTime = type(yielded) == "number" and math.max(yielded, 0) or 0
			entry.resumeAt = self.clock + waitTime
		end
	end

	function task.spawn(fn, ...)
		local co = coroutine.create(fn)
		local entry = {
			co = co,
			args = table.pack(...),
			resumeAt = self.clock,
			dead = false,
			cancelled = false,
		}
		table.insert(self._threads, entry)
		resumeEntry(entry)
		return co
	end

	function task.wait(seconds)
		coroutine.yield(math.max(seconds or 0, 0))
	end

	function task.defer(fn, ...)
		table.insert(self._deferred, { fn = fn, args = table.pack(...) })
	end

	function task.delay(seconds, fn, ...)
		table.insert(self._timers, {
			at = self.clock + math.max(seconds or 0, 0),
			fn = fn,
			args = table.pack(...),
		})
	end

	function task.cancel(thread)
		for _, entry in ipairs(self._threads) do
			if entry.co == thread then
				entry.cancelled = true
				entry.dead = true
			end
		end
	end

	function self._resume(entry)
		resumeEntry(entry)
	end

	function self.step(dt)
		self.clock = self.clock + dt
		runService.Heartbeat:Fire(dt)

		local now = self.clock
		local running = coroutine.running()
		local threads = self._threads
		local threadCount = #threads
		for index = 1, threadCount do
			local entry = threads[index]
			if entry.co ~= running and not entry.dead and entry.resumeAt and entry.resumeAt <= now then
				resumeEntry(entry)
			end
		end

		local survivingTimers = {}
		for _, timer in ipairs(self._timers) do
			if timer.at <= now then
				task.spawn(timer.fn, table.unpack(timer.args, 1, timer.args.n))
			else
				table.insert(survivingTimers, timer)
			end
		end
		self._timers = survivingTimers

		local deferred = self._deferred
		self._deferred = {}
		for _, item in ipairs(deferred) do
			task.spawn(item.fn, table.unpack(item.args, 1, item.args.n))
		end

		if #threads > 128 then
			local alive = {}
			for _, entry in ipairs(threads) do
				if not entry.dead then
					table.insert(alive, entry)
				end
			end
			self._threads = alive
		end
	end

	function self.advance(seconds)
		local frame = 1 / 60
		local remaining = seconds
		while remaining > 1e-9 do
			local dt = math.min(frame, remaining)
			self.step(dt)
			remaining = remaining - dt
		end
	end

	function self.advanceFrames(count)
		for _ = 1, count or 1 do
			self.step(1 / 60)
		end
	end

	function self.runThread(fn, maxSeconds)
		local startErrors = #self.errors
		local co = task.spawn(fn)
		local start = self.clock
		local limit = maxSeconds or 10
		while coroutine.status(co) ~= "dead" and (self.clock - start) < limit do
			self.step(1 / 60)
		end
		local timedOut = coroutine.status(co) ~= "dead"
		if timedOut then
			task.cancel(co)
			table.insert(self.errors, ("test timed out after %.2fs"):format(limit))
		end
		local captured = {}
		for index = startErrors + 1, #self.errors do
			table.insert(captured, self.errors[index])
		end
		return #captured == 0, captured
	end

	function self.createPlayer(name)
		self._playerCount = self._playerCount + 1
		local player = newInstance("Player", name or ("Player" .. self._playerCount))
		player.UserId = 100000 + self._playerCount
		player.DisplayName = player.Name
		attachParent(player, playersService)
		playersService.PlayerAdded:Fire(player)
		return player
	end

	function self.removePlayer(player)
		playersService.PlayerRemoving:Fire(player)
		player:Destroy()
	end

	function self.setClientContext(player)
		self._currentClient = player
	end

	function self.withClient(player, fn)
		local previous = self._currentClient
		self._currentClient = player
		local ok, result = pcall(fn)
		self._currentClient = previous
		if not ok then
			error(result, 0)
		end
		return result
	end

	function self.now()
		return self.clock
	end

	self.services = services
	self.playersService = playersService
	self.runService = runService
	self.replicatedStorage = replicatedStorage
	self.serverScriptService = serverScriptService

	return self
end

return RobloxShim
