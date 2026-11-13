--!strict
-- Inbound pipeline: structural validation, rate limiting, payload limits,
-- schema validation, middleware, then handler dispatch. Server-side checks are
-- ordered cheapest-first so expensive payload work only happens for messages
-- that already passed basic validation.

local Protocol = require(script.Parent.Protocol)
local Registry = require(script.Parent.Registry)
local RequestManager = require(script.Parent.RequestManager)
local Middleware = require(script.Parent.Parent.Features.Middleware)
local RateLimiter = require(script.Parent.Parent.Security.RateLimiter)
local Validator = require(script.Parent.Parent.Security.Validator)

local Dispatcher = {}
Dispatcher.__index = Dispatcher

export type Config = {
	Side: "Server" | "Client",
	Registry: Registry.Registry,
	Middleware: Middleware.Middleware,
	RateLimiter: RateLimiter.RateLimiter,
	RequestManager: RequestManager.RequestManager,
	Stats: any,
	ProtocolLimits: Protocol.Limits,
	PayloadLimits: Validator.PayloadLimits,
	DefaultRate: number,
	DefaultBurst: number,
	DecodePayload: (data: any, flags: number?) -> (any, string?),
	SendEnvelope: (destination: any, envelope: Protocol.Envelope, priority: number, reliable: boolean) -> (),
	Hooks: {
		OnDrop: ((payload: any) -> ())?,
		OnRateLimited: ((payload: any) -> ())?,
		OnError: ((payload: any) -> ())?,
	}?,
}

type Stats = {
	PacketsReceived: number,
	MessagesReceived: number,
	MalformedPackets: number,
	DroppedPackets: number,
	RateLimited: number,
	MiddlewareRejected: number,
	PermissionsDenied: number,
	PayloadRejected: number,
	Errors: number,
	[any]: any,
}

type State = {
	_config: Config,
	_destroyed: boolean,
}

export type Dispatcher = State & {
	GetSide: (self: Dispatcher) -> "Server" | "Client",
	HandlePacket: (self: Dispatcher, packet: any, reliableLane: boolean, player: any, now: number) -> (),
	Destroy: (self: Dispatcher) -> (),
}

local RESPONSE_PRIORITY = 2
local SERVER_KEY = "Server"

function Dispatcher.new(config: Config): Dispatcher
	local self: Dispatcher = setmetatable({
		_config = config,
		_destroyed = false,
	}, Dispatcher) :: any
	return self
end

local function getSide(self: Dispatcher): "Server" | "Client"
	return self._config.Side
end
Dispatcher.GetSide = getSide

local function statsOf(self: Dispatcher): Stats
	return self._config.Stats :: Stats
end

local function invokeHook(self: Dispatcher, hook: ((payload: any) -> ())?, payload: any)
	if hook == nil then
		return
	end
	local ok, err = pcall(hook, payload)
	if not ok then
		warn("ThunderNet hook error: " .. tostring(err))
	end
end

local function makePayload(code: string, message: string, extra: any?): any
	local payload: any = { Code = code, Message = message }
	if extra ~= nil then
		for key, value in pairs(extra) do
			payload[key] = value
		end
	end
	return payload
end

local function notifyDrop(self: Dispatcher, code: string, message: string, extra: any?)
	local hooks = self._config.Hooks
	if hooks ~= nil then
		invokeHook(self, hooks.OnDrop, makePayload(code, message, extra))
	end
end

local function notifyRateLimited(self: Dispatcher, player: any, channel: string?, retryAfter: number?)
	local hooks = self._config.Hooks
	if hooks ~= nil then
		invokeHook(self, hooks.OnRateLimited, makePayload("RATE_LIMITED", "Rate limit exceeded", {
			Player = player,
			Channel = channel,
			RetryAfter = retryAfter,
		}))
	end
end

local function notifyError(self: Dispatcher, code: string, message: string, extra: any?)
	local hooks = self._config.Hooks
	if hooks ~= nil then
		invokeHook(self, hooks.OnError, makePayload(code, message, extra))
	end
end

local function rejectionText(rejection: any): string
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
	return "Rejected by middleware"
end

local function respondRequestError(
	self: Dispatcher,
	player: any,
	incomingKey: any,
	id: string,
	code: string,
	message: string,
	now: number
)
	local response = Protocol.Response(id, false, {
		Code = code,
		Message = message,
	})
	self._config.RequestManager:CompleteIncoming(incomingKey, id, response, now)
	self._config.SendEnvelope(player, response, RESPONSE_PRIORITY, true)
	return response
end

local function dispatchEvent(self: Dispatcher, envelope: Protocol.Envelope, reliableLane: boolean, player: any, now: number)
	local config = self._config
	local stats = statsOf(self)
	local name = envelope[2] :: string

	local definition = config.Registry:GetEvent(name)
	if definition == nil then
		if config.Side == "Client" then
			definition = config.Registry:CreateEvent(name)
		else
			stats.DroppedPackets += 1
			notifyDrop(self, "UNKNOWN_EVENT", "Unknown event", { Channel = name, Player = player })
			return
		end
	end
	local event = definition :: Registry.Event

	if config.Side == "Server" and not reliableLane and not event:IsUnreliable() then
		stats.DroppedPackets += 1
		notifyDrop(self, "INVALID_LANE", "Event is not allowed on the unreliable lane", { Channel = name, Player = player })
		return
	end

	local data, decodeError = config.DecodePayload(envelope[3], envelope[4])
	if decodeError ~= nil then
		stats.PayloadRejected += 1
		notifyDrop(self, "INVALID_PAYLOAD", decodeError, { Channel = name, Player = player })
		return
	end

	local options = event:GetOptions()

	if config.Side == "Server" then
		local rateLimit = options.RateLimit
		if rateLimit ~= nil then
			local allowed, retryAfter = config.RateLimiter:Allow(player, name, rateLimit.Rate, rateLimit.Burst, now)
			if not allowed then
				stats.RateLimited += 1
				notifyRateLimited(self, player, name, retryAfter)
				return
			end
		end
		local permission = event:GetPermission()
		if permission ~= nil then
			local okCall, allowed = pcall(permission, player, data)
			if not okCall or not allowed then
				stats.PermissionsDenied += 1
				notifyDrop(self, "PERMISSION_DENIED", "Permission denied", { Channel = name, Player = player })
				return
			end
		end
	end

	local payloadOk, payloadReason = Validator.CheckPayload(data, config.PayloadLimits)
	if not payloadOk then
		stats.PayloadRejected += 1
		notifyDrop(self, "INVALID_PAYLOAD", payloadReason or "Payload failed validation", { Channel = name, Player = player })
		return
	end

	if options.Schema ~= nil then
		local schemaOk, schemaReason = Validator.Validate(data, options.Schema, name)
		if not schemaOk then
			stats.PayloadRejected += 1
			notifyDrop(self, "INVALID_PAYLOAD", schemaReason or "Payload failed schema validation", { Channel = name, Player = player })
			return
		end
	end

	if options.Validate ~= nil then
		local validate = options.Validate :: any
		local okCall, valid = pcall(validate, data)
		if not okCall or not valid then
			stats.PayloadRejected += 1
			notifyDrop(self, "INVALID_PAYLOAD", "Payload failed custom validation", { Channel = name, Player = player })
			return
		end
	end

	local globalMiddlewareCount = config.Middleware:GetCount()
	local eventMiddlewareCount = event:GetMiddlewareCount()
	if globalMiddlewareCount > 0 or eventMiddlewareCount > 0 then
		local context: Middleware.Context = {
			Data = data,
			Channel = name,
			Kind = "Event",
			Side = config.Side,
			Player = player,
		}
		if globalMiddlewareCount > 0 then
			local pipelineOk, finalContext, rejection = config.Middleware:Run(context)
			if not pipelineOk then
				stats.MiddlewareRejected += 1
				notifyDrop(self, "MIDDLEWARE_REJECTED", rejectionText(rejection), { Channel = name, Player = player })
				return
			end
			context = finalContext :: Middleware.Context
		end
		if eventMiddlewareCount > 0 then
			local pipelineOk, finalContext, rejection = event:RunMiddleware(context)
			if not pipelineOk then
				stats.MiddlewareRejected += 1
				notifyDrop(self, "MIDDLEWARE_REJECTED", rejectionText(rejection), { Channel = name, Player = player })
				return
			end
			context = finalContext :: Middleware.Context
		end
		data = context.Data
	end

	if config.Side == "Server" then
		event.OnServerEvent:Fire(player, data)
	else
		event.OnClientEvent:Fire(data)
	end
end

local function dispatchRequest(self: Dispatcher, envelope: Protocol.Envelope, player: any, now: number)
	local config = self._config
	local stats = statsOf(self)
	local name = envelope[2] :: string
	local requestId = envelope[3] :: string
	local incomingKey = player or SERVER_KEY

	local status, cached = config.RequestManager:BeginIncoming(incomingKey, requestId, now)
	if status == "cached" and cached ~= nil then
		config.SendEnvelope(player, cached, RESPONSE_PRIORITY, true)
		return
	elseif status == "cancelled" then
		config.SendEnvelope(player, Protocol.Response(requestId, false, {
			Code = "CANCELLED",
			Message = "The request was cancelled by the sender",
		}), RESPONSE_PRIORITY, true)
		return
	end

	local data, decodeError = config.DecodePayload(envelope[4], envelope[5])
	if decodeError ~= nil then
		notifyDrop(self, "INVALID_PAYLOAD", decodeError, { Channel = name, Player = player, RequestId = requestId })
		respondRequestError(
			self,
			player,
			incomingKey,
			requestId,
			"INVALID_PAYLOAD",
			"Could not decode the request payload",
			now
		)
		return
	end

	local payloadOk, payloadReason = Validator.CheckPayload(data, config.PayloadLimits)
	if not payloadOk then
		notifyDrop(self, "INVALID_PAYLOAD", payloadReason or "Request payload failed validation", { Channel = name, Player = player, RequestId = requestId })
		respondRequestError(
			self,
			player,
			incomingKey,
			requestId,
			"INVALID_PAYLOAD",
			"The request payload failed validation",
			now
		)
		return
	end

	if config.Middleware:GetCount() > 0 then
		local context: Middleware.Context = {
			Data = data,
			Channel = name,
			Kind = "Request",
			Side = config.Side,
			Player = player,
			RequestId = requestId,
		}
		local pipelineOk, finalContext, rejection = config.Middleware:Run(context)
		if not pipelineOk then
			stats.MiddlewareRejected += 1
			notifyDrop(self, "MIDDLEWARE_REJECTED", rejectionText(rejection), { Channel = name, Player = player, RequestId = requestId })
			local code = "REJECTED"
			local message = "The request was rejected"
			if type(rejection) == "table" then
				if type(rejection.Code) == "string" then
					code = rejection.Code
				end
				if type(rejection.Message) == "string" then
					message = rejection.Message
				end
			end
			respondRequestError(self, player, incomingKey, requestId, code, message, now)
			return
		end
		data = (finalContext :: Middleware.Context).Data
	end

	local handler = config.Registry:GetRequestHandler(name)
	if handler == nil then
		notifyDrop(self, "NO_HANDLER", "No request handler is registered", { Channel = name, Player = player, RequestId = requestId })
		respondRequestError(
			self,
			player,
			incomingKey,
			requestId,
			"NO_HANDLER",
			"No request handler is registered",
			now
		)
		return
	end

	local response: Protocol.Envelope
	local okCall, result = pcall(handler, player, data)
	if okCall then
		response = Protocol.Response(requestId, true, result)
	else
		stats.Errors += 1
		notifyError(self, "HANDLER_ERROR", "Request handler failed", {
			Channel = name,
			Player = player,
			RequestId = requestId,
			Error = tostring(result),
		})
		warn(("ThunderNet request handler %q failed: %s"):format(name, tostring(result)))
		response = Protocol.Response(requestId, false, {
			Code = "HANDLER_ERROR",
			Message = "Request handler failed",
		})
	end

	config.RequestManager:CompleteIncoming(incomingKey, requestId, response, now)
	config.SendEnvelope(player, response, RESPONSE_PRIORITY, true)
end

local function dispatchResponse(self: Dispatcher, envelope: Protocol.Envelope, player: any)
	local config = self._config
	local stats = statsOf(self)

	if envelope[3] == true then
		local data, decodeError = config.DecodePayload(envelope[4], envelope[5])
		if decodeError ~= nil then
			stats.PayloadRejected += 1
			stats.DroppedPackets += 1
			notifyDrop(self, "INVALID_PAYLOAD", decodeError, { Player = player })
			return
		end
		local normalized = Protocol.Response(envelope[2], true, data)
		if not config.RequestManager:HandleResponse(normalized, player) then
			stats.DroppedPackets += 1
			notifyDrop(self, "UNKNOWN_RESPONSE", "Response has no matching pending request", { Player = player })
		end
	else
		if not config.RequestManager:HandleResponse(envelope, player) then
			stats.DroppedPackets += 1
			notifyDrop(self, "UNKNOWN_RESPONSE", "Response has no matching pending request", { Player = player })
		end
	end
end

local function dispatchEnvelope(self: Dispatcher, envelope: Protocol.Envelope, reliableLane: boolean, player: any, now: number)
	if self._destroyed then
		return
	end
	local config = self._config
	local stats = statsOf(self)
	stats.MessagesReceived += 1

	local op = envelope[1]
	if not reliableLane and op ~= Protocol.Ops.Event then
		stats.DroppedPackets += 1
		notifyDrop(self, "INVALID_LANE", "Only events may use the unreliable lane", { Player = player })
		return
	end

	if config.Side == "Server" then
		local allowed, retryAfter = config.RateLimiter:Allow(player, "", config.DefaultRate, config.DefaultBurst, now)
		if not allowed then
			stats.RateLimited += 1
			notifyRateLimited(self, player, nil, retryAfter)
			if op == Protocol.Ops.Request then
				respondRequestError(
					self,
					player,
					player,
					envelope[3],
					"RATE_LIMITED",
					"Too many requests",
					now
				)
			end
			return
		end
	end

	if op == Protocol.Ops.Event then
		dispatchEvent(self, envelope, reliableLane, player, now)
	elseif op == Protocol.Ops.Request then
		dispatchRequest(self, envelope, player, now)
	elseif op == Protocol.Ops.Response then
		dispatchResponse(self, envelope, player)
	elseif op == Protocol.Ops.Cancel then
		config.RequestManager:HandleCancel(player or SERVER_KEY, envelope[2], now)
	else
		stats.DroppedPackets += 1
		notifyDrop(self, "UNKNOWN_OPCODE", "Unknown envelope opcode", { Player = player })
	end
end

local function handlePacket(self: Dispatcher, packet: any, reliableLane: boolean, player: any, now: number)
	if self._destroyed then
		return
	end
	local config = self._config
	local stats = statsOf(self)

	local messages, unpackError = Protocol.Unpack(packet, config.ProtocolLimits)
	if messages == nil then
		stats.MalformedPackets += 1
		local reason: string = unpackError or "unknown"
		stats.LastMalformedReason = reason
		notifyDrop(self, "MALFORMED_PACKET", reason, { Player = player })
		return
	end
	stats.PacketsReceived += 1

	for index = 1, #messages do
		local ok, err = pcall(dispatchEnvelope, self, messages[index], reliableLane, player, now)
		if not ok then
			stats.Errors += 1
			notifyError(self, "DISPATCH_ERROR", tostring(err), { Player = player })
			warn("ThunderNet dispatch error: " .. tostring(err))
		end
	end
end
Dispatcher.HandlePacket = handlePacket

local function destroy(self: Dispatcher)
	self._destroyed = true
end
Dispatcher.Destroy = destroy

return Dispatcher
