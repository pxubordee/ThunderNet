--!strict
-- Request/response (RPC) manager.
--
-- Outbound: unique ids, pending registry, timeouts, exponential backoff with
-- jitter, bounded retries, cancellation, promise integration, per-player
-- cleanup.
--
-- Inbound: duplicate-request protection with a cached-response window so that
-- client retries after a lost response never re-execute a non-idempotent
-- handler. Cancelled request ids are remembered briefly so a late arrival is
-- not executed at all.

local Protocol = require(script.Parent.Protocol)
local Promise = require(script.Parent.Parent.Utilities.Promise)
local RetryManager = require(script.Parent.Parent.Features.RetryManager)

local RequestManager = {}
RequestManager.__index = RequestManager

export type Side = "Server" | "Client"

export type Config = {
	Timeout: number?,
	MaxAttempts: number?,
	BackoffBase: number?,
	BackoffMax: number?,
	Jitter: number?,
	DedupeTtl: number?,
	DedupeMaxEntries: number?,
	Random: (() -> number)?,
}

export type Sender = (destination: any, envelope: Protocol.Envelope, priority: number) -> ()

export type RequestOptions = {
	Timeout: number?,
	MaxAttempts: number?,
	Idempotent: boolean?,
}

type ResolvedConfig = {
	Timeout: number,
	MaxAttempts: number,
	BackoffBase: number,
	BackoffMax: number,
	Jitter: number,
	DedupeTtl: number,
	DedupeMaxEntries: number,
	Random: (() -> number)?,
}

type Waiting = "response" | "retry"

type PendingRecord = {
	Id: string,
	Envelope: Protocol.Envelope,
	Destination: any,
	Promise: Promise.Promise,
	Attempts: number,
	MaxAttempts: number,
	Timeout: number,
	Waiting: Waiting,
	NextAt: number,
}

type DedupeEntry = {
	Envelope: Protocol.Envelope,
	ExpiresAt: number,
	Channel: string,
}

type InFlightEntry = {
	Channel: string,
	StartedAt: number,
}

type PlayerIncoming = {
	Cache: { [string]: DedupeEntry },
	Order: { string },
	InFlight: { [string]: InFlightEntry },
	Cancelled: { [string]: number },
	CancelledOrder: { string },
}

export type Counters = {
	RequestsSent: number,
	Retries: number,
	TimedOut: number,
	Cancelled: number,
}

type State = {
	_side: Side,
	_sender: Sender,
	_config: ResolvedConfig,
	_retry: RetryManager.RetryManager,
	_pending: { [string]: PendingRecord },
	_incoming: { [any]: PlayerIncoming },
	_counter: number,
	_token: string,
	_destroyed: boolean,
	counters: Counters,
}

export type RequestManager = State & {
	GetSide: (self: RequestManager) -> Side,
	Request: (
		self: RequestManager,
		destination: any,
		channel: string,
		data: any,
		now: number,
		options: RequestOptions?
	) -> Promise.Promise,
	HandleResponse: (self: RequestManager, envelope: Protocol.Envelope, senderPlayer: any) -> boolean,
	Step: (self: RequestManager, now: number) -> (),
	GetPendingCount: (self: RequestManager) -> number,
	BeginIncoming: (self: RequestManager, player: any, channel: string, id: string, now: number) -> (string, Protocol.Envelope?),
	CompleteIncoming: (
		self: RequestManager,
		player: any,
		channel: string,
		id: string,
		response: Protocol.Envelope,
		now: number
	) -> (),
	HandleCancel: (self: RequestManager, player: any, id: string, now: number) -> (),
	GetDedupeCount: (self: RequestManager, player: any?) -> number,
	OnPlayerRemoving: (self: RequestManager, player: any) -> (),
	Destroy: (self: RequestManager) -> (),
}

local REQUEST_PRIORITY = 2

local function resolveConfig(config: Config?): ResolvedConfig
	local resolved: ResolvedConfig = {
		Timeout = (config and config.Timeout) or 5,
		MaxAttempts = (config and config.MaxAttempts) or 3,
		BackoffBase = (config and config.BackoffBase) or 0.5,
		BackoffMax = (config and config.BackoffMax) or 8,
		Jitter = (config and config.Jitter) or 0.2,
		DedupeTtl = (config and config.DedupeTtl) or 30,
		DedupeMaxEntries = (config and config.DedupeMaxEntries) or 256,
		Random = config and config.Random,
	}
	if resolved.Timeout <= 0 then
		error("RequestManager Timeout must be positive", 3)
	end
	if resolved.DedupeTtl <= 0 then
		error("RequestManager DedupeTtl must be positive", 3)
	end
	if resolved.DedupeMaxEntries < 1 or resolved.DedupeMaxEntries % 1 ~= 0 then
		error("RequestManager DedupeMaxEntries must be a positive integer", 3)
	end
	return resolved
end

function RequestManager.new(side: Side, sender: Sender, config: Config?): RequestManager
	if type(sender) ~= "function" then
		error("RequestManager requires a sender callback", 2)
	end
	local resolved = resolveConfig(config)
	local self: RequestManager = setmetatable({
		_side = side,
		_sender = sender,
		_config = resolved,
		_retry = RetryManager.new({
			MaxAttempts = resolved.MaxAttempts,
			BaseDelay = resolved.BackoffBase,
			MaxDelay = resolved.BackoffMax,
			Jitter = resolved.Jitter,
			Random = resolved.Random,
		}),
		_pending = {} :: { [string]: PendingRecord },
		_incoming = {} :: { [any]: PlayerIncoming },
		_counter = 0,
		_token = string.format("%x", math.random(1, 0xFFFFFF)),
		_destroyed = false,
		counters = {
			RequestsSent = 0,
			Retries = 0,
			TimedOut = 0,
			Cancelled = 0,
		},
	}, RequestManager) :: any
	return self
end

local function getSide(self: RequestManager): Side
	return self._side
end
RequestManager.GetSide = getSide

local function nextId(self: RequestManager): string
	self._counter += 1
	local prefix = if self._side == "Client" then "c" else "s"
	return string.format("%s%s-%d", prefix, self._token, self._counter)
end

local function cancelRequest(self: RequestManager, id: string)
	local record = self._pending[id]
	if record == nil then
		return
	end
	self._pending[id] = nil
	self.counters.Cancelled += 1
	self._sender(record.Destination, Protocol.Cancel(id), REQUEST_PRIORITY)
end

local function request(
	self: RequestManager,
	destination: any,
	channel: string,
	data: any,
	now: number,
	options: RequestOptions?
): Promise.Promise
	if self._destroyed then
		error("RequestManager is destroyed", 3)
	end
	if self._side == "Server" and destination == nil then
		error("Server requests require a destination player", 3)
	end
	if type(channel) ~= "string" or #channel == 0 then
		error("Request channel must be a non-empty string", 3)
	end

	local timeout = self._config.Timeout
	local maxAttempts = self._config.MaxAttempts
	if options ~= nil then
		if options.Timeout ~= nil then
			if type(options.Timeout) ~= "number" or options.Timeout <= 0 then
				error("Request Timeout must be positive", 3)
			end
			timeout = options.Timeout
		end
		if options.MaxAttempts ~= nil then
			if type(options.MaxAttempts) ~= "number" or options.MaxAttempts < 1 or options.MaxAttempts % 1 ~= 0 then
				error("Request MaxAttempts must be a positive integer", 3)
			end
			maxAttempts = options.MaxAttempts
		end
		if options.Idempotent == false then
			maxAttempts = 1
		end
	end

	local id = nextId(self)
	local envelope = Protocol.Request(channel, id, data)
	local promise = Promise.new()
	local record: PendingRecord = {
		Id = id,
		Envelope = envelope,
		Destination = destination,
		Promise = promise,
		Attempts = 1,
		MaxAttempts = maxAttempts,
		Timeout = timeout,
		Waiting = "response",
		NextAt = now + timeout,
	}
	self._pending[id] = record
	self.counters.RequestsSent += 1
	self._sender(destination, envelope, REQUEST_PRIORITY)

	local manager = self
	promise:OnCancel(function()
		cancelRequest(manager, id)
	end)

	return promise
end
RequestManager.Request = request

local function handleResponse(self: RequestManager, envelope: Protocol.Envelope, senderPlayer: any): boolean
	if self._destroyed then
		return false
	end
	if envelope[1] ~= Protocol.Ops.Response then
		return false
	end
	local id = envelope[2]
	if type(id) ~= "string" then
		return false
	end
	local record = self._pending[id]
	if record == nil then
		return false
	end
	if self._side == "Server" and record.Destination ~= senderPlayer then
		return false
	end
	self._pending[id] = nil
	if envelope[3] == true then
		record.Promise:Resolve(envelope[4])
	else
		record.Promise:Reject(envelope[4])
	end
	return true
end
RequestManager.HandleResponse = handleResponse

local function step(self: RequestManager, now: number)
	if self._destroyed then
		return
	end
	local expired: { PendingRecord } = {}

	for _, record in pairs(self._pending) do
		if now >= record.NextAt then
			if record.Waiting == "response" then
				if record.Attempts < record.MaxAttempts then
					record.Waiting = "retry"
					record.NextAt = now + self._retry:NextDelay(record.Attempts)
				else
					table.insert(expired, record)
				end
			else
				record.Attempts += 1
				record.Waiting = "response"
				record.NextAt = now + record.Timeout
				self.counters.Retries += 1
				self._sender(record.Destination, record.Envelope, REQUEST_PRIORITY)
			end
		end
	end

	for _, record in ipairs(expired) do
		if self._pending[record.Id] == record then
			self._pending[record.Id] = nil
			self.counters.TimedOut += 1
			self._sender(record.Destination, Protocol.Cancel(record.Id), REQUEST_PRIORITY)
			record.Promise:Reject({
				Code = "TIMEOUT",
				Message = "Request timed out after " .. tostring(record.Timeout) .. "s per attempt",
			})
		end
	end
end
RequestManager.Step = step

local function getPendingCount(self: RequestManager): number
	local count = 0
	for _ in pairs(self._pending) do
		count += 1
	end
	return count
end
RequestManager.GetPendingCount = getPendingCount

local function newIncoming(): PlayerIncoming
	return {
		Cache = {} :: { [string]: DedupeEntry },
		Order = {} :: { string },
		InFlight = {} :: { [string]: InFlightEntry },
		Cancelled = {} :: { [string]: number },
		CancelledOrder = {} :: { string },
	}
end

local function getIncoming(self: RequestManager, player: any, create: boolean): PlayerIncoming?
	local incoming = self._incoming[player]
	if incoming == nil and create then
		incoming = newIncoming()
		self._incoming[player] = incoming
	end
	return incoming
end

local function beginIncoming(
	self: RequestManager,
	player: any,
	channel: string,
	id: string,
	now: number
): (string, Protocol.Envelope?)
	local incoming = getIncoming(self, player, true) :: PlayerIncoming

	local cancelledAt = incoming.Cancelled[id]
	if cancelledAt ~= nil then
		if now - cancelledAt <= self._config.DedupeTtl then
			return "cancelled", nil
		end
		incoming.Cancelled[id] = nil
	end

	local inFlight = incoming.InFlight[id]
	if inFlight ~= nil then
		if now - inFlight.StartedAt > self._config.DedupeTtl then
			incoming.InFlight[id] = nil
		elseif inFlight.Channel ~= channel then
			return "mismatch", nil
		else
			return "inflight", nil
		end
	end

	local entry = incoming.Cache[id]
	if entry ~= nil then
		if now < entry.ExpiresAt then
			if entry.Channel ~= channel then
				return "mismatch", nil
			end
			return "cached", entry.Envelope
		end
		incoming.Cache[id] = nil
	end

	incoming.InFlight[id] = { Channel = channel, StartedAt = now }
	return "execute", nil
end
RequestManager.BeginIncoming = beginIncoming

local function completeIncoming(
	self: RequestManager,
	player: any,
	channel: string,
	id: string,
	response: Protocol.Envelope,
	now: number
)
	local incoming = getIncoming(self, player, true) :: PlayerIncoming
	incoming.InFlight[id] = nil
	if incoming.Cache[id] == nil then
		table.insert(incoming.Order, id)
	end
	incoming.Cache[id] = {
		Envelope = response,
		ExpiresAt = now + self._config.DedupeTtl,
		Channel = channel,
	}
	while #incoming.Order > self._config.DedupeMaxEntries do
		local evicted = table.remove(incoming.Order, 1) :: string
		incoming.Cache[evicted] = nil
	end
end
RequestManager.CompleteIncoming = completeIncoming

local function handleCancel(self: RequestManager, player: any, id: string, now: number)
	local incoming = getIncoming(self, player, true) :: PlayerIncoming
	if incoming.Cancelled[id] == nil then
		table.insert(incoming.CancelledOrder, id)
	end
	incoming.Cancelled[id] = now
	while #incoming.CancelledOrder > self._config.DedupeMaxEntries do
		local evicted = table.remove(incoming.CancelledOrder, 1) :: string
		incoming.Cancelled[evicted] = nil
	end
end
RequestManager.HandleCancel = handleCancel

local function getDedupeCount(self: RequestManager, player: any?): number
	if player ~= nil then
		local incoming = getIncoming(self, player, false)
		if incoming == nil then
			return 0
		end
		local count = 0
		for _ in pairs(incoming.Cache) do
			count += 1
		end
		return count
	end
	local total = 0
	for _, incoming in pairs(self._incoming) do
		for _ in pairs(incoming.Cache) do
			total += 1
		end
	end
	return total
end
RequestManager.GetDedupeCount = getDedupeCount

local function onPlayerRemoving(self: RequestManager, player: any)
	self._incoming[player] = nil
	local stale: { PendingRecord } = {}
	for id, record in pairs(self._pending) do
		if record.Destination == player then
			table.insert(stale, record)
			self._pending[id] = nil
		end
	end
	for _, record in ipairs(stale) do
		record.Promise:Reject({
			Code = "PLAYER_LEFT",
			Message = "The destination player left before responding",
		})
	end
end
RequestManager.OnPlayerRemoving = onPlayerRemoving

local function destroy(self: RequestManager)
	if self._destroyed then
		return
	end
	self._destroyed = true
	local pending = self._pending
	self._pending = {}
	self._incoming = {}
	for _, record in pairs(pending) do
		record.Promise:Reject({
			Code = "DESTROYED",
			Message = "RequestManager was destroyed",
		})
	end
end
RequestManager.Destroy = destroy

return RequestManager
