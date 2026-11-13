--!strict
-- ThunderNet session: wires transports, batching, dispatch, middleware, RPC,
-- security and statistics into one lifecycle-managed object.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(script.Parent.Parent.Types.Types)
local Protocol = require(script.Parent.Protocol)
local Scheduler = require(script.Parent.Scheduler)
local Registry = require(script.Parent.Registry)
local RequestManager = require(script.Parent.RequestManager)
local Dispatcher = require(script.Parent.Dispatcher)
local Reliable = require(script.Parent.Parent.Transport.Reliable)
local Unreliable = require(script.Parent.Parent.Transport.Unreliable)
local Middleware = require(script.Parent.Parent.Features.Middleware)
local Batcher = require(script.Parent.Parent.Features.Batcher)
local Channels = require(script.Parent.Parent.Features.Channels)
local Serializer = require(script.Parent.Parent.Features.Serializer)
local Compression = require(script.Parent.Parent.Features.Compression)
local RateLimiter = require(script.Parent.Parent.Security.RateLimiter)
local Validator = require(script.Parent.Parent.Security.Validator)
local Promise = require(script.Parent.Parent.Utilities.Promise)
local Signal = require(script.Parent.Parent.Utilities.Signal)
local Janitor = require(script.Parent.Parent.Utilities.Janitor)

local Network = {}
Network.__index = Network

export type Side = "Server" | "Client"

export type NetworkConfig = Types.NetworkConfig
export type NetworkStats = Types.NetworkStats
export type Event = Registry.Event
export type TypedEvent<T = any> = Registry.TypedEvent<T>
export type EventOptions = Registry.EventOptions
export type Timer = Scheduler.Timer
export type RequestOptions = RequestManager.RequestOptions

type StatsCounters = {
	PacketsSent: number,
	PacketsReceived: number,
	MessagesSent: number,
	MessagesReceived: number,
	BatchesSent: number,
	QueueOverflow: number,
	OutboundRejected: number,
	BytesSentEstimate: number,
	CompressionSavingsBytes: number,
	MalformedPackets: number,
	DroppedPackets: number,
	RateLimited: number,
	MiddlewareRejected: number,
	PermissionsDenied: number,
	PayloadRejected: number,
	Dispatches: number,
	DispatchTimeMs: number,
	Errors: number,
	MessagesByPriority: { number },
}

local SERVER_DESTINATION = "Server"
local PROTOCOL_VERSION = 1

local function emit(signal: Signal.Signal, payload: any)
	if signal:GetConnectionCount() == 0 then
		return
	end
	local ok, err = pcall(signal.Fire, signal, payload)
	if not ok then
		warn("ThunderNet hook error: " .. tostring(err))
	end
end

local PRESETS: { [string]: NetworkConfig } = {
	Standard = {},
	Minimal = {
		Stats = false,
		Batch = { MaxBatchSize = 32, MaxBatchBytes = 8192 },
		Request = { MaxAttempts = 1 },
		RateLimit = { Rate = 60, Burst = 120 },
		Payload = { MaxBytes = 32768, MaxDepth = 6 },
	},
	Hardened = {
		Stats = true,
		Request = { DedupeTtl = 60, DedupeMaxEntries = 512 },
		RateLimit = { Rate = 60, Burst = 120 },
		Payload = { MaxBytes = 16384, MaxDepth = 6 },
	},
}

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in pairs(value) do
		copy[key] = deepCopy(child)
	end
	return copy
end

local function mergeInto(base: any, overrides: any)
	for key, value in pairs(overrides) do
		if type(value) == "table" and type(base[key]) == "table" then
			mergeInto(base[key], value)
		else
			base[key] = deepCopy(value)
		end
	end
end

local function applyPreset(config: NetworkConfig): NetworkConfig
	local presetName = config.Preset or "Standard"
	local preset = PRESETS[presetName]
	if preset == nil then
		error(("Unknown Preset %q"):format(tostring(presetName)), 3)
	end
	local merged = deepCopy(preset) :: any
	mergeInto(merged, config)
	return merged :: NetworkConfig
end

type State = {
	_side: Side,
	_name: string,
	_config: NetworkConfig,
	_stats: StatsCounters,
	_statsEnabled: boolean,
	_serializer: Serializer.Serializer,
	_serializerFallback: boolean,
	_serializerFallbackWarned: boolean,
	_compression: Compression.Compression,
	_compressionEnabled: boolean,
	_protocolLimits: Protocol.Limits,
	_payloadLimits: Validator.PayloadLimits,
	_defaultRate: number,
	_defaultBurst: number,
	_scheduler: Scheduler.Scheduler,
	_middleware: Middleware.Middleware,
	_outboundMiddleware: Middleware.Middleware,
	_registry: Registry.Registry,
	_batcher: Batcher.Batcher,
	_requestManager: RequestManager.RequestManager,
	_rateLimiter: RateLimiter.RateLimiter,
	_dispatcher: Dispatcher.Dispatcher,
	_janitor: Janitor.Janitor,
	_reliable: any,
	_unreliable: any,
	_folder: any,
	_ownsRemotes: boolean,
	_channels: { [string]: Channels.Channel },
	_destroyed: boolean,
	OnError: Signal.Signal,
	OnDrop: Signal.Signal,
	OnRateLimited: Signal.Signal,
}

export type Network = State & {
	IsServer: (self: Network) -> boolean,
	IsClient: (self: Network) -> boolean,
	GetName: (self: Network) -> string,
	CreateEvent: <T>(self: Network, name: string, options: EventOptions?) -> TypedEvent<T>,
	GetEvent: <T>(self: Network, name: string, options: EventOptions?) -> TypedEvent<T>?,
	Use: (self: Network, middlewareFunction: Middleware.MiddlewareFunction) -> number,
	Unuse: (self: Network, token: number) -> boolean,
	UseOutbound: (self: Network, middlewareFunction: Middleware.MiddlewareFunction) -> number,
	UnuseOutbound: (self: Network, token: number) -> boolean,
	OnRequest: <TRequest, TResult>(
		self: Network,
		name: string,
		handler: (player: any, data: TRequest) -> TResult
	) -> (),
	InvokeServer: <TRequest, TResult>(
		self: Network,
		name: string,
		data: TRequest,
		options: RequestOptions?
	) -> Promise.PromiseOf<TResult>,
	InvokeClient: <TRequest, TResult>(
		self: Network,
		player: any,
		name: string,
		data: TRequest,
		options: RequestOptions?
	) -> Promise.PromiseOf<TResult>,
	CreateChannel: (self: Network, name: string, defaults: EventOptions?) -> Channels.Channel,
	After: (self: Network, seconds: number, callback: () -> ()) -> Timer,
	GetStats: (self: Network) -> NetworkStats,
	Destroy: (self: Network) -> (),
	_step: (self: Network, now: number) -> (),
	_handlePacket: (self: Network, reliableLane: boolean, player: any, packet: any) -> (),
	_decodePayload: (self: Network, data: any, flags: number?) -> (any, string?),
	_encodePayload: (self: Network, data: any) -> (any, number, number),
	_encodeEnvelope: (self: Network, envelope: Protocol.Envelope) -> (Protocol.Envelope, number),
	_enqueue: (
		self: Network,
		destination: any,
		envelope: Protocol.Envelope,
		priority: number,
		reliable: boolean,
		bytes: number
	) -> (),
	_sendEvent: (self: Network, destination: any, channel: string, data: any, priority: number, reliable: boolean) -> (),
	_sendEnvelope: (self: Network, destination: any, envelope: Protocol.Envelope, priority: number, reliable: boolean) -> (),
	_flushSender: (self: Network, destination: any, reliable: boolean, messages: { any }) -> (),
	_onPlayerRemoving: (self: Network, player: any) -> (),
}

local function validatePositiveInteger(value: any, label: string, minimum: number)
	if type(value) ~= "number" or value % 1 ~= 0 or value < minimum then
		error(("%s must be an integer >= %d"):format(label, minimum), 3)
	end
end

local function resolveConfig(config: NetworkConfig)
	local name = config.Name or "ThunderNet"
	if type(name) ~= "string" or #name == 0 or #name > 64 then
		error("Network Name must be a non-empty string up to 64 characters", 3)
	end

	local limitsConfig: Types.ProtocolLimits = config.Limits or {}
	local protocolLimits: Protocol.Limits = {
		MaxBatchMessages = limitsConfig.MaxBatchMessages or 128,
		MaxNameLength = limitsConfig.MaxNameLength or 128,
		MaxRequestIdLength = limitsConfig.MaxRequestIdLength or 64,
	}
	validatePositiveInteger(protocolLimits.MaxBatchMessages, "Limits.MaxBatchMessages", 1)
	validatePositiveInteger(protocolLimits.MaxNameLength, "Limits.MaxNameLength", 1)
	validatePositiveInteger(protocolLimits.MaxRequestIdLength, "Limits.MaxRequestIdLength", 1)

	local payloadConfig: Types.PayloadLimits = config.Payload or {}
	local payloadLimits: Validator.PayloadLimits = {
		MaxBytes = payloadConfig.MaxBytes or 65536,
		MaxDepth = payloadConfig.MaxDepth or 8,
	}
	validatePositiveInteger(payloadLimits.MaxBytes, "Payload.MaxBytes", 1)
	validatePositiveInteger(payloadLimits.MaxDepth, "Payload.MaxDepth", 1)

	local rateConfig: Types.RateLimitConfig = config.RateLimit or {}
	local defaultRate = rateConfig.Rate or 120
	local defaultBurst = rateConfig.Burst or 240
	if type(defaultRate) ~= "number" or defaultRate <= 0 then
		error("RateLimit.Rate must be positive", 3)
	end
	if type(defaultBurst) ~= "number" or defaultBurst < 1 then
		error("RateLimit.Burst must be at least 1", 3)
	end
	local packetRate = rateConfig.PacketRate or math.max(defaultRate, 300)
	local packetBurst = rateConfig.PacketBurst or math.max(defaultBurst, 600)
	if type(packetRate) ~= "number" or packetRate <= 0 then
		error("RateLimit.PacketRate must be positive", 3)
	end
	if type(packetBurst) ~= "number" or packetBurst < 1 then
		error("RateLimit.PacketBurst must be at least 1", 3)
	end

	return {
		Name = name,
		ProtocolLimits = protocolLimits :: Protocol.Limits,
		PayloadLimits = payloadLimits,
		DefaultRate = defaultRate,
		DefaultBurst = defaultBurst,
		PacketRate = packetRate,
		PacketBurst = packetBurst,
		StatsEnabled = config.Stats ~= false,
	}
end

local function resolveSerializerLimits(config: NetworkConfig, payloadLimits: Validator.PayloadLimits): Serializer.Limits
	local configured: any = config.Serializer and config.Serializer.Limits
	local limits: any = {
		MaxBytes = payloadLimits.MaxBytes,
		MaxDepth = payloadLimits.MaxDepth,
	}
	if configured then
		for key, value in pairs(configured) do
			limits[key] = value
		end
	end
	return limits :: Serializer.Limits
end

function Network.new(side: Side, config: NetworkConfig?): Network
	if side ~= "Server" and side ~= "Client" then
		error("Network side must be \"Server\" or \"Client\"", 2)
	end
	local fullConfig = applyPreset(config or {})
	local resolved = resolveConfig(fullConfig)

	local stats: StatsCounters = {
		PacketsSent = 0,
		PacketsReceived = 0,
		MessagesSent = 0,
		MessagesReceived = 0,
		BatchesSent = 0,
		QueueOverflow = 0,
		OutboundRejected = 0,
		BytesSentEstimate = 0,
		CompressionSavingsBytes = 0,
		MalformedPackets = 0,
		DroppedPackets = 0,
		RateLimited = 0,
		MiddlewareRejected = 0,
		PermissionsDenied = 0,
		PayloadRejected = 0,
		Dispatches = 0,
		DispatchTimeMs = 0,
		Errors = 0,
		MessagesByPriority = { 0, 0, 0, 0, 0 },
	}

	local serializerConfig = fullConfig.Serializer
	local serializer = Serializer.new({
		Enabled = serializerConfig ~= nil and serializerConfig.Enabled == true,
		Limits = resolveSerializerLimits(fullConfig, resolved.PayloadLimits),
	})
	local compression = Compression.new(fullConfig.Compression)
	local compressionEnabled = fullConfig.Compression ~= nil and fullConfig.Compression.Enabled == true

	local self: Network = setmetatable({
		_side = side,
		_name = resolved.Name,
		_config = fullConfig,
		_stats = stats,
		_statsEnabled = resolved.StatsEnabled,
		_serializer = serializer,
		_serializerFallback = serializerConfig ~= nil and serializerConfig.FallbackToNative == true,
		_serializerFallbackWarned = false,
		_compression = compression,
		_compressionEnabled = compressionEnabled,
		_protocolLimits = resolved.ProtocolLimits,
		_payloadLimits = resolved.PayloadLimits,
		_defaultRate = resolved.DefaultRate,
		_defaultBurst = resolved.DefaultBurst,
		_scheduler = Scheduler.new(os.clock()),
		_middleware = Middleware.new(),
		_outboundMiddleware = Middleware.new(),
		_janitor = Janitor.new(),
		_reliable = nil,
		_unreliable = nil,
		_folder = nil,
		_ownsRemotes = false,
		_channels = {} :: { [string]: Channels.Channel },
		_destroyed = false,
		OnError = Signal.new(),
		OnDrop = Signal.new(),
		OnRateLimited = Signal.new(),
	}, Network) :: any

	self._batcher = Batcher.new(fullConfig.Batch, function(destination, reliable, messages)
		self:_flushSender(destination, reliable, messages)
	end)

	self._requestManager = RequestManager.new(side, function(destination, envelope, priority)
		self:_sendEnvelope(destination, envelope, priority, true)
	end, fullConfig.Request)

	self._rateLimiter = RateLimiter.new({
		DefaultRate = resolved.DefaultRate,
		DefaultBurst = resolved.DefaultBurst,
	})

	self._registry = Registry.new(side, function(destination, channel, data, priority, reliable)
		self:_sendEvent(destination, channel, data, priority, reliable)
	end)

	self._dispatcher = Dispatcher.new({
		Side = side,
		Registry = self._registry,
		Middleware = self._middleware,
		RateLimiter = self._rateLimiter,
		RequestManager = self._requestManager,
		Stats = self._stats,
		ProtocolLimits = self._protocolLimits,
		PayloadLimits = self._payloadLimits,
		DefaultRate = self._defaultRate,
		DefaultBurst = self._defaultBurst,
		PacketRate = resolved.PacketRate,
		PacketBurst = resolved.PacketBurst,
		DecodePayload = function(data, flags)
			return self:_decodePayload(data, flags)
		end,
		SendEnvelope = function(destination, envelope, priority, reliable)
			self:_sendEnvelope(destination, envelope, priority, reliable)
		end,
		Hooks = {
			OnDrop = function(payload)
				emit(self.OnDrop, payload)
			end,
			OnRateLimited = function(payload)
				emit(self.OnRateLimited, payload)
			end,
			OnError = function(payload)
				emit(self.OnError, payload)
			end,
		},
	})

	if side == "Server" then
		local existing = ReplicatedStorage:FindFirstChild(resolved.Name)
		if existing ~= nil then
			error(("A ThunderNet instance named %q already exists"):format(resolved.Name), 2)
		end
		local folder = Instance.new("Folder")
		folder.Name = resolved.Name
		folder.Parent = ReplicatedStorage
		local reliableInstance = Instance.new("RemoteEvent")
		reliableInstance.Name = "Reliable"
		reliableInstance.Parent = folder
		local unreliableInstance = Instance.new("UnreliableRemoteEvent")
		unreliableInstance.Name = "Unreliable"
		unreliableInstance.Parent = folder

		local configuration = Instance.new("Folder")
		configuration.Name = "Configuration"
		configuration:SetAttribute("ProtocolVersion", PROTOCOL_VERSION)
		configuration:SetAttribute("SerializerEnabled", serializer:IsEnabled())
		configuration:SetAttribute("CompressionEnabled", compressionEnabled)
		configuration.Parent = folder

		self._folder = folder
		self._ownsRemotes = true
		self._reliable = Reliable.new(reliableInstance)
		self._unreliable = Unreliable.new(unreliableInstance)

		self._janitor:Add(reliableInstance.OnServerEvent:Connect(function(player: any, packet: any)
			self:_handlePacket(true, player, packet)
		end))
		self._janitor:Add(unreliableInstance.OnServerEvent:Connect(function(player: any, packet: any)
			self:_handlePacket(false, player, packet)
		end))
		self._janitor:Add(Players.PlayerRemoving:Connect(function(player: any)
			self:_onPlayerRemoving(player)
		end))
	else
		local folder = ReplicatedStorage:WaitForChild(resolved.Name, 10)
		if folder == nil then
			error(("ThunderNet remotes %q were not found; initialize the server first"):format(resolved.Name), 2)
		end
		local configuration = folder:WaitForChild("Configuration", 10)
		if configuration == nil then
			error("ThunderNet configuration was not found; initialize the server first", 2)
		end
		local version = configuration:GetAttribute("ProtocolVersion")
		local versionDeadline = os.clock() + 2
		while version == nil and os.clock() < versionDeadline do
			task.wait(0)
			version = configuration:GetAttribute("ProtocolVersion")
		end
		if version ~= PROTOCOL_VERSION then
			error(("ThunderNet protocol version mismatch (server %s, client %s)"):format(
				tostring(version),
				tostring(PROTOCOL_VERSION)
			), 2)
		end
		if configuration:GetAttribute("SerializerEnabled") ~= serializer:IsEnabled() then
			error("ThunderNet Serializer configuration mismatch; enable or disable it on both sides", 2)
		end
		if configuration:GetAttribute("CompressionEnabled") ~= compressionEnabled then
			error("ThunderNet Compression configuration mismatch; enable or disable it on both sides", 2)
		end

		local reliableInstance = folder:WaitForChild("Reliable", 10)
		local unreliableInstance = folder:WaitForChild("Unreliable", 10)
		if reliableInstance == nil or unreliableInstance == nil then
			error("ThunderNet remotes are incomplete; re-join the server", 2)
		end
		self._reliable = Reliable.new(reliableInstance)
		self._unreliable = Unreliable.new(unreliableInstance)

		self._janitor:Add(reliableInstance.OnClientEvent:Connect(function(packet: any)
			self:_handlePacket(true, nil, packet)
		end))
		self._janitor:Add(unreliableInstance.OnClientEvent:Connect(function(packet: any)
			self:_handlePacket(false, nil, packet)
		end))
	end

	self._janitor:Add(RunService.Heartbeat:Connect(function()
		self:_step(os.clock())
	end))

	return self
end

function Network.IsServer(self: Network): boolean
	return self._side == "Server"
end

function Network.IsClient(self: Network): boolean
	return self._side == "Client"
end

function Network.GetName(self: Network): string
	return self._name
end

function Network._step(self: Network, now: number)
	if self._destroyed then
		return
	end
	self._scheduler:Step(now)
	self._requestManager:Step(now)
	self._batcher:Step(now)
end

function Network._encodePayload(self: Network, data: any): (any, number, number)
	if not self._serializer:IsEnabled() and not self._compressionEnabled then
		return data, 0, Serializer.Measure(data, self._payloadLimits.MaxBytes)
	end

	local value = data
	local flags = 0
	if self._serializer:IsEnabled() then
		local ok, encoded = pcall(self._serializer.Encode, self._serializer, data)
		if not ok then
			if self._serializerFallback then
				if not self._serializerFallbackWarned then
					self._serializerFallbackWarned = true
					warn("ThunderNet serializer fallback to native: " .. tostring(encoded))
				end
				return data, 0, Serializer.Measure(data, self._payloadLimits.MaxBytes)
			end
			error(encoded, 2)
		end
		value = encoded
		flags = bit32.bor(flags, Protocol.Flags.Serialized)
	end
	if self._compressionEnabled and type(value) == "string" then
		local compressed, wasCompressed = self._compression:Compress(value)
		if wasCompressed then
			self._stats.CompressionSavingsBytes += #value - #compressed
			value = compressed
			flags = bit32.bor(flags, Protocol.Flags.Compressed)
		end
	end

	local byteSize = if flags ~= 0 then #value else Serializer.Measure(data, self._payloadLimits.MaxBytes)
	if flags == 0 then
		value = data
	end
	return value, flags, byteSize
end

function Network._decodePayload(self: Network, data: any, flags: number?): (any, string?)
	if flags == nil or flags == 0 then
		return data, nil
	end
	local payload = data
	if bit32.band(flags, Protocol.Flags.Compressed) ~= 0 then
		local decompressed, err = self._compression:Decompress(payload)
		if decompressed == nil then
			return nil, err or "decompression failed"
		end
		payload = decompressed
	end
	if bit32.band(flags, Protocol.Flags.Serialized) ~= 0 then
		local decoded, err = self._serializer:Decode(payload)
		if err ~= nil then
			return nil, err
		end
		return decoded, nil
	end
	return payload, nil
end

function Network._encodeEnvelope(self: Network, envelope: Protocol.Envelope): (Protocol.Envelope, number)
	local op = envelope[1]
	local dataIndex: number
	local flagsIndex: number
	if op == Protocol.Ops.Event then
		dataIndex, flagsIndex = 3, 4
	elseif op == Protocol.Ops.Request then
		dataIndex, flagsIndex = 4, 5
	elseif op == Protocol.Ops.Response then
		if envelope[3] ~= true then
			return envelope, 0
		end
		dataIndex, flagsIndex = 4, 5
	else
		return envelope, 0
	end

	if envelope[flagsIndex] ~= nil then
		local payload = envelope[dataIndex]
		local byteSize = if type(payload) == "string" then #payload
			else Serializer.Measure(payload, self._payloadLimits.MaxBytes)
		return envelope, byteSize
	end

	local value, flags, byteSize = self:_encodePayload(envelope[dataIndex])
	if flags ~= 0 then
		envelope[dataIndex] = value
		envelope[flagsIndex] = flags
	end
	return envelope, byteSize
end

function Network._enqueue(self: Network, destination: any, envelope: Protocol.Envelope, priority: number, reliable: boolean, bytes: number)
	if self._destroyed then
		error("Network is destroyed", 2)
	end
	if not self._batcher:Push(destination, envelope, priority, reliable, bytes, os.clock()) then
		self._stats.QueueOverflow += 1
		emit(self.OnDrop, {
			Code = "QUEUE_OVERFLOW",
			Message = "Message dropped because the queue is full",
			Channel = if type(envelope[2]) == "string" then envelope[2] else nil,
			Destination = destination,
		})
		return
	end
	self._stats.MessagesByPriority[priority] += 1
	self._stats.BytesSentEstimate += bytes
end

local function rejectionMessage(rejection: any): string
	if type(rejection) == "table" then
		if type(rejection.Message) == "string" then
			return rejection.Message
		end
		if type(rejection.Code) == "string" then
			return rejection.Code
		end
	end
	if rejection ~= nil then
		return tostring(rejection)
	end
	return "Rejected by outbound middleware"
end

function Network._sendEvent(self: Network, destination: any, channel: string, data: any, priority: number, reliable: boolean)
	if self._destroyed then
		error("Network is destroyed", 2)
	end
	if self._outboundMiddleware:GetCount() > 0 then
		local player = destination
		if destination == "All" or destination == "Server" then
			player = nil
		elseif type(destination) == "table" and destination.Kind ~= nil then
			player = nil
		end
		local context: Middleware.Context = {
			Data = data,
			Channel = channel,
			Kind = "Event",
			Side = self._side,
			Player = player,
			Destination = destination,
			Priority = priority,
			Unreliable = not reliable,
		}
		local pipelineOk, finalContext, rejection = self._outboundMiddleware:Run(context)
		if not pipelineOk then
			self._stats.OutboundRejected += 1
			emit(self.OnDrop, {
				Code = "OUTBOUND_REJECTED",
				Message = rejectionMessage(rejection),
				Channel = channel,
				Player = player,
			})
			return
		end
		data = (finalContext :: Middleware.Context).Data
	end
	local value, flags, bytes = self:_encodePayload(data)
	local envelope = if flags ~= 0 then Protocol.Event(channel, value, flags) else Protocol.Event(channel, data)

	if type(destination) == "table" and destination.Kind ~= nil then
		if self._side ~= "Server" then
			error("Only the server can broadcast events", 3)
		end
		if destination.Kind == "Many" then
			local players: any = destination.Players
			if type(players) ~= "table" then
				error("FireMany requires a list of players", 4)
			end
			for _, player in ipairs(players) do
				self:_enqueue(player, envelope, priority, reliable, bytes)
			end
		elseif destination.Kind == "Except" then
			local excluded = destination.Player
			for _, player in ipairs(Players:GetPlayers()) do
				if player ~= excluded then
					self:_enqueue(player, envelope, priority, reliable, bytes)
				end
			end
		else
			error("Unknown broadcast destination", 4)
		end
	elseif destination == "All" then
		if self._side ~= "Server" then
			error("Only the server can broadcast events", 3)
		end
		for _, player in ipairs(Players:GetPlayers()) do
			self:_enqueue(player, envelope, priority, reliable, bytes)
		end
	elseif destination == "Server" then
		if self._side ~= "Client" then
			error("The server cannot send events to itself", 3)
		end
		self:_enqueue(SERVER_DESTINATION, envelope, priority, reliable, bytes)
	else
		if self._side ~= "Server" then
			error("Clients cannot address other players", 3)
		end
		self:_enqueue(destination, envelope, priority, reliable, bytes)
	end
end

function Network._sendEnvelope(self: Network, destination: any, envelope: Protocol.Envelope, priority: number, reliable: boolean)
	local encoded, bytes = self:_encodeEnvelope(envelope)
	local key = destination
	if self._side == "Client" then
		if destination ~= nil then
			error("Clients can only send to the server", 3)
		end
		key = SERVER_DESTINATION
	else
		if destination == nil then
			error("Server messages require a destination player", 3)
		end
	end
	self:_enqueue(key, encoded, priority, reliable, bytes)
end

function Network._flushSender(self: Network, destination: any, reliable: boolean, messages: { any })
	if self._destroyed then
		return
	end
	local transport = if reliable then self._reliable else self._unreliable
	local packet = if #messages == 1 then messages[1] else Protocol.Batch(messages)

	self._stats.PacketsSent += 1
	self._stats.BatchesSent += 1
	self._stats.MessagesSent += #messages

	if self._side == "Client" then
		transport:FireServer(packet)
	else
		transport:FireClient(destination, packet)
	end
end

function Network._handlePacket(self: Network, reliableLane: boolean, player: any, packet: any)
	if self._destroyed then
		return
	end
	if self._statsEnabled then
		local started = os.clock()
		local ok, err = pcall(self._dispatcher.HandlePacket, self._dispatcher, packet, reliableLane, player, started)
		if not ok then
			self._stats.Errors += 1
			emit(self.OnError, { Code = "INBOUND_ERROR", Message = tostring(err) })
			warn("ThunderNet inbound error: " .. tostring(err))
		end
		self._stats.Dispatches += 1
		self._stats.DispatchTimeMs += (os.clock() - started) * 1000
	else
		local ok, err = pcall(self._dispatcher.HandlePacket, self._dispatcher, packet, reliableLane, player, os.clock())
		if not ok then
			self._stats.Errors += 1
			warn("ThunderNet inbound error: " .. tostring(err))
		end
	end
end

function Network._onPlayerRemoving(self: Network, player: any)
	if self._destroyed then
		return
	end
	self._batcher:RemoveDestination(player)
	self._requestManager:OnPlayerRemoving(player)
	self._rateLimiter:RemovePlayer(player)
end

function Network.CreateEvent<T>(self: Network, name: string, options: EventOptions?): TypedEvent<T>
	if self._destroyed then
		error("Network is destroyed", 2)
	end
	return self._registry:CreateEvent(name, options) :: any
end

function Network.GetEvent<T>(self: Network, name: string, options: EventOptions?): TypedEvent<T>?
	if self._destroyed then
		error("Network is destroyed", 2)
	end
	local existing = self._registry:GetEvent(name)
	if existing ~= nil then
		return existing :: any
	end
	if self._side == "Client" then
		return self._registry:CreateEvent(name, options) :: any
	end
	return nil
end

function Network.Use(self: Network, middlewareFunction: Middleware.MiddlewareFunction): number
	if self._destroyed then
		error("Network is destroyed", 2)
	end
	return self._middleware:Use(middlewareFunction)
end

function Network.Unuse(self: Network, token: number): boolean
	if self._destroyed then
		return false
	end
	return self._middleware:Remove(token)
end

function Network.UseOutbound(self: Network, middlewareFunction: Middleware.MiddlewareFunction): number
	if self._destroyed then
		error("Network is destroyed", 2)
	end
	return self._outboundMiddleware:Use(middlewareFunction)
end

function Network.UnuseOutbound(self: Network, token: number): boolean
	if self._destroyed then
		return false
	end
	return self._outboundMiddleware:Remove(token)
end

function Network.OnRequest<TRequest, TResult>(self: Network, 
	name: string,
	handler: (player: any, data: TRequest) -> TResult
)
	if self._destroyed then
		error("Network is destroyed", 2)
	end
	self._registry:SetRequestHandler(name, handler :: any)
end

function Network.InvokeServer<TRequest, TResult>(
	self: Network,
	name: string,
	data: TRequest,
	options: RequestOptions?
): Promise.PromiseOf<TResult>
	if self._destroyed then
		error("Network is destroyed", 2)
	end
	if self._side ~= "Client" then
		error("InvokeServer can only be called from the client", 2)
	end
	return self._requestManager:Request(nil, name, data, os.clock(), options) :: any
end

function Network.InvokeClient<TRequest, TResult>(
	self: Network,
	player: any,
	name: string,
	data: TRequest,
	options: RequestOptions?
): Promise.PromiseOf<TResult>
	if self._destroyed then
		error("Network is destroyed", 2)
	end
	if self._side ~= "Server" then
		error("InvokeClient can only be called from the server", 2)
	end
	if player == nil then
		error("InvokeClient requires a player", 2)
	end
	return self._requestManager:Request(player, name, data, os.clock(), options) :: any
end

function Network.CreateChannel(self: Network, name: string, defaults: EventOptions?): Channels.Channel
	if self._destroyed then
		error("Network is destroyed", 2)
	end
	local channel = Channels.new(self, name, defaults)
	self._channels[name] = channel
	return channel
end

function Network.After(self: Network, seconds: number, callback: () -> ()): Timer
	if self._destroyed then
		error("Network is destroyed", 2)
	end
	return self._scheduler:After(seconds, callback)
end

function Network.GetStats(self: Network): NetworkStats
	local counters = self._stats
	local batches = counters.BatchesSent
	local requests = self._requestManager
	local priorityCounts: { number } = (table.create(5) :: any)
	for index = 1, 5 do
		priorityCounts[index] = counters.MessagesByPriority[index]
	end
	return {
		PacketsSent = counters.PacketsSent,
		PacketsReceived = counters.PacketsReceived,
		MessagesSent = counters.MessagesSent,
		MessagesReceived = counters.MessagesReceived,
		BatchesSent = batches,
		QueueOverflow = counters.QueueOverflow,
		OutboundRejected = counters.OutboundRejected,
		AverageBatchSize = if batches > 0 then counters.MessagesSent / batches else 0,
		BytesSentEstimate = counters.BytesSentEstimate,
		CompressionSavingsBytes = counters.CompressionSavingsBytes,
		QueueDepth = self._batcher:GetQueueDepth(),
		RequestsSent = requests.counters.RequestsSent,
		RequestsPending = requests:GetPendingCount(),
		RequestsTimedOut = requests.counters.TimedOut,
		Retries = requests.counters.Retries,
		MalformedPackets = counters.MalformedPackets,
		DroppedPackets = counters.DroppedPackets,
		RateLimited = counters.RateLimited,
		MiddlewareRejected = counters.MiddlewareRejected,
		PermissionsDenied = counters.PermissionsDenied,
		PayloadRejected = counters.PayloadRejected,
		Dispatches = counters.Dispatches,
		DispatchTimeMs = counters.DispatchTimeMs,
		AverageDispatchTimeMs = if counters.Dispatches > 0 then counters.DispatchTimeMs / counters.Dispatches else 0,
		MessagesByPriority = priorityCounts,
	}
end

function Network.Destroy(self: Network)
	if self._destroyed then
		return
	end
	self._destroyed = true

	self._janitor:Destroy()
	self._scheduler:Destroy()
	self._middleware:Destroy()
	self._outboundMiddleware:Destroy()
	self._registry:Destroy()
	self._batcher:Destroy()
	self._requestManager:Destroy()
	self._rateLimiter:Destroy()
	self.OnError:Destroy()
	self.OnDrop:Destroy()
	self.OnRateLimited:Destroy()
	self._channels = {}

	if self._ownsRemotes and self._folder ~= nil then
		self._folder:Destroy()
		self._folder = nil
	end
end

return Network
