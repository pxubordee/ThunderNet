--!strict
-- Wire protocol: compact array envelopes and strict structural validation.
-- Nothing from the network is trusted before ValidateEnvelope/Unpack succeeds.
--
-- Envelope layouts (array indices):
--   Event:    { 1, channel, data, flags? }
--   Request:  { 2, channel, requestId, data, flags? }
--   Response: { 3, requestId, ok, payloadOrError, flags? }
--   Cancel:   { 4, requestId }
--   Batch:    { 0, { envelope... } }
-- Flags is a bitmask: 1 = serialized payload, 2 = compressed payload. When any
-- flag is set the data field must be a string.

local Protocol = {}

Protocol.Ops = table.freeze({
	Batch = 0,
	Event = 1,
	Request = 2,
	Response = 3,
	Cancel = 4,
})

Protocol.Flags = table.freeze({
	Serialized = 1,
	Compressed = 2,
})

export type Envelope = { any }

export type Limits = {
	MaxBatchMessages: number,
	MaxNameLength: number,
	MaxRequestIdLength: number,
}

local OPS = Protocol.Ops
local MAX_FLAGS = Protocol.Flags.Serialized + Protocol.Flags.Compressed

function Protocol.Event(channel: string, data: any, flags: number?): Envelope
	local envelope: Envelope = { OPS.Event, channel, data }
	if flags and flags ~= 0 then
		table.insert(envelope, flags)
	end
	return envelope
end

function Protocol.Request(channel: string, requestId: string, data: any, flags: number?): Envelope
	local envelope: Envelope = { OPS.Request, channel, requestId, data }
	if flags and flags ~= 0 then
		table.insert(envelope, flags)
	end
	return envelope
end

function Protocol.Response(requestId: string, ok: boolean, data: any, flags: number?): Envelope
	local envelope: Envelope = { OPS.Response, requestId, ok, data }
	if flags and flags ~= 0 then
		table.insert(envelope, flags)
	end
	return envelope
end

function Protocol.Cancel(requestId: string): Envelope
	return { OPS.Cancel, requestId }
end

function Protocol.Batch(messages: { Envelope }): Envelope
	return { OPS.Batch, messages }
end

local function isPrintableName(value: any, maxLength: number): boolean
	if type(value) ~= "string" then
		return false
	end
	local length = #value
	if length == 0 or length > maxLength then
		return false
	end
	for index = 1, length do
		local byte = string.byte(value, index) :: number
		if byte < 32 or byte > 126 then
			return false
		end
	end
	return true
end

function Protocol.ValidateRequestId(value: any, maxLength: number): boolean
	if type(value) ~= "string" then
		return false
	end
	local length = #value
	if length == 0 or length > maxLength then
		return false
	end
	for index = 1, length do
		local byte = string.byte(value, index) :: number
		local isDigit = byte >= 48 and byte <= 57
		local isUpper = byte >= 65 and byte <= 90
		local isLower = byte >= 97 and byte <= 122
		local isSeparator = byte == 45 or byte == 46 or byte == 95
		if not (isDigit or isUpper or isLower or isSeparator) then
			return false
		end
	end
	return true
end

local function validateFlags(flags: any, payload: any): (boolean, string?)
	if type(flags) ~= "number" or flags ~= flags // 1 then
		return false, "invalid flags"
	end
	if flags < 0 or flags > MAX_FLAGS then
		return false, "invalid flags"
	end
	if flags ~= 0 and type(payload) ~= "string" then
		return false, "encoded payload must be a string"
	end
	return true, nil
end

function Protocol.ValidateEnvelope(envelope: any, limits: Limits): (boolean, string?)
	if type(envelope) ~= "table" then
		return false, "envelope must be a table"
	end
	local op = envelope[1]
	if type(op) ~= "number" then
		return false, "missing opcode"
	end

	if op == OPS.Event then
		local length = #envelope
		if length ~= 3 and length ~= 4 then
			return false, "malformed event envelope"
		end
		if not isPrintableName(envelope[2], limits.MaxNameLength) then
			return false, "invalid event name"
		end
		if length == 4 then
			return validateFlags(envelope[4], envelope[3])
		end
		return true, nil
	elseif op == OPS.Request then
		local length = #envelope
		if length ~= 4 and length ~= 5 then
			return false, "malformed request envelope"
		end
		if not isPrintableName(envelope[2], limits.MaxNameLength) then
			return false, "invalid event name"
		end
		if not Protocol.ValidateRequestId(envelope[3], limits.MaxRequestIdLength) then
			return false, "invalid request id"
		end
		if length == 5 then
			return validateFlags(envelope[5], envelope[4])
		end
		return true, nil
	elseif op == OPS.Response then
		local length = #envelope
		if length ~= 4 and length ~= 5 then
			return false, "malformed response envelope"
		end
		if not Protocol.ValidateRequestId(envelope[2], limits.MaxRequestIdLength) then
			return false, "invalid request id"
		end
		local ok = envelope[3]
		if type(ok) ~= "boolean" then
			return false, "response ok flag must be a boolean"
		end
		if ok then
			if length == 5 then
				return validateFlags(envelope[5], envelope[4])
			end
			return true, nil
		end
		if length == 5 then
			return false, "error responses cannot carry encoding flags"
		end
		local errorPayload = envelope[4]
		if type(errorPayload) ~= "table" then
			return false, "error payload must be a table"
		end
		if type(errorPayload.Code) ~= "string" or type(errorPayload.Message) ~= "string" then
			return false, "error payload requires Code and Message strings"
		end
		return true, nil
	elseif op == OPS.Cancel then
		if #envelope ~= 2 then
			return false, "malformed cancel envelope"
		end
		if not Protocol.ValidateRequestId(envelope[2], limits.MaxRequestIdLength) then
			return false, "invalid request id"
		end
		return true, nil
	end

	return false, "unknown opcode"
end

-- Returns a dense list of validated envelopes, or nil plus a reason.
function Protocol.Unpack(packet: any, limits: Limits): ({ Envelope }?, string?)
	if type(packet) ~= "table" then
		return nil, "packet must be a table"
	end
	local op = packet[1]
	if type(op) ~= "number" then
		return nil, "missing opcode"
	end

	if op == OPS.Batch then
		if packet[3] ~= nil then
			return nil, "malformed batch container"
		end
		local messages = packet[2]
		if type(messages) ~= "table" then
			return nil, "batch messages must be a table"
		end
		local count = 0
		while messages[count + 1] ~= nil do
			count += 1
			if count > limits.MaxBatchMessages then
				return nil, "batch exceeds the message limit"
			end
		end
		if count == 0 then
			return nil, "empty batch"
		end
		local list: { Envelope } = (table.create(count) :: any)
		for index = 1, count do
			local envelope = messages[index]
			if type(envelope) ~= "table" then
				return nil, "batch message must be a table"
			end
			if envelope[1] == OPS.Batch then
				return nil, "nested batches are not allowed"
			end
			local ok, reason = Protocol.ValidateEnvelope(envelope, limits)
			if not ok then
				return nil, reason
			end
			list[index] = envelope
		end
		return list, nil
	end

	local ok, reason = Protocol.ValidateEnvelope(packet, limits)
	if not ok then
		return nil, reason
	end
	return { packet }, nil
end

return Protocol
