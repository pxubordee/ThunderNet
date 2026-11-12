--!strict
-- Optional binary serializer for payloads made of supported Luau/Roblox
-- primitives. The default wire path sends native Roblox values untouched; this
-- codec exists so payloads can be compressed and to make byte accounting
-- predictable. Unsupported values (functions, Instances, EnumItems, buffers)
-- are rejected at encode time.
--
-- The decoder is hardened: every read is bounds-checked, strings are length
-- capped, table counts are capped, nesting depth is capped, and trailing bytes
-- are rejected. It never throws to callers.

local Serializer = {}

export type Limits = {
	MaxDepth: number?,
	MaxStringLength: number?,
	MaxEntries: number?,
	MaxBytes: number?,
}

export type Config = {
	Enabled: boolean?,
	Limits: Limits?,
}

local DEFAULTS = {
	MaxDepth = 16,
	MaxStringLength = 65535,
	MaxEntries = 100000,
	MaxBytes = 1048576,
}

local TAG_NIL = 0
local TAG_FALSE = 1
local TAG_TRUE = 2
local TAG_NUMBER = 3
local TAG_STRING = 4
local TAG_TABLE = 5
local TAG_VECTOR2 = 6
local TAG_VECTOR3 = 7
local TAG_CFRAME = 8
local TAG_COLOR3 = 9
local TAG_UDIM = 10
local TAG_UDIM2 = 11

local NATIVE_MEASURE_SIZES: { [string]: number } = {
	Vector2 = 8,
	Vector3 = 12,
	CFrame = 48,
	Color3 = 12,
	UDim = 8,
	UDim2 = 16,
	Instance = 8,
	EnumItem = 4,
}

type ResolvedLimits = {
	MaxDepth: number,
	MaxStringLength: number,
	MaxEntries: number,
	MaxBytes: number,
}

local function resolveLimits(overrides: Limits?): ResolvedLimits
	local resolved: ResolvedLimits = {
		MaxDepth = DEFAULTS.MaxDepth,
		MaxStringLength = DEFAULTS.MaxStringLength,
		MaxEntries = DEFAULTS.MaxEntries,
		MaxBytes = DEFAULTS.MaxBytes,
	}
	if overrides then
		if overrides.MaxDepth ~= nil then
			resolved.MaxDepth = overrides.MaxDepth
		end
		if overrides.MaxStringLength ~= nil then
			resolved.MaxStringLength = overrides.MaxStringLength
		end
		if overrides.MaxEntries ~= nil then
			resolved.MaxEntries = overrides.MaxEntries
		end
		if overrides.MaxBytes ~= nil then
			resolved.MaxBytes = overrides.MaxBytes
		end
	end
	return resolved
end

type Writer = {
	buffer: buffer,
	size: number,
	capacity: number,
	maxBytes: number,
}

local function ensure(writer: Writer, count: number)
	local required = writer.size + count
	if required > writer.maxBytes then
		error("serialized payload exceeds the byte limit", 0)
	end
	if required <= writer.capacity then
		return
	end
	local newCapacity = math.max(writer.capacity * 2, required)
	newCapacity = math.min(newCapacity, writer.maxBytes)
	local newBuffer = buffer.create(newCapacity)
	buffer.copy(newBuffer, 0, writer.buffer, 0, writer.size)
	writer.buffer = newBuffer
	writer.capacity = newCapacity
end

local function writeU8(writer: Writer, value: number)
	ensure(writer, 1)
	buffer.writeu8(writer.buffer, writer.size, value)
	writer.size += 1
end

local function writeU32(writer: Writer, value: number)
	ensure(writer, 4)
	buffer.writeu32(writer.buffer, writer.size, value)
	writer.size += 4
end

local function writeF32(writer: Writer, value: number)
	ensure(writer, 4)
	buffer.writef32(writer.buffer, writer.size, value)
	writer.size += 4
end

local function writeF64(writer: Writer, value: number)
	ensure(writer, 8)
	buffer.writef64(writer.buffer, writer.size, value)
	writer.size += 8
end

local function writeI32(writer: Writer, value: number)
	ensure(writer, 4)
	buffer.writei32(writer.buffer, writer.size, value)
	writer.size += 4
end

local function writeRaw(writer: Writer, value: string)
	ensure(writer, #value)
	buffer.writestring(writer.buffer, writer.size, value)
	writer.size += #value
end

type EncoderState = {
	entries: number,
}

local function encodeValue(
	writer: Writer,
	value: any,
	limits: ResolvedLimits,
	depth: number,
	path: string,
	state: EncoderState
)
	local valueType = typeof(value)

	if valueType == "nil" then
		writeU8(writer, TAG_NIL)
	elseif valueType == "boolean" then
		writeU8(writer, if value then TAG_TRUE else TAG_FALSE)
	elseif valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error(("%s: cannot serialize a non-finite number"):format(path), 0)
		end
		writeU8(writer, TAG_NUMBER)
		writeF64(writer, value)
	elseif valueType == "string" then
		if #value > limits.MaxStringLength then
			error(("%s: string exceeds MaxStringLength"):format(path), 0)
		end
		writeU8(writer, TAG_STRING)
		writeU32(writer, #value)
		writeRaw(writer, value)
	elseif valueType == "table" then
		if depth > limits.MaxDepth then
			error(("%s: table exceeds MaxDepth"):format(path), 0)
		end
		local entryCount = 0
		for key in pairs(value) do
			entryCount += 1
			state.entries += 1
			if state.entries > limits.MaxEntries then
				error(("%s: table exceeds MaxEntries"):format(path), 0)
			end
			local keyType = typeof(key)
			if keyType ~= "string" and keyType ~= "number" then
				error(("%s: unsupported table key type %s"):format(path, keyType), 0)
			end
		end
		if entryCount * 2 > 0xFFFFFFFF then
			error(("%s: table has too many entries"):format(path), 0)
		end
		writeU8(writer, TAG_TABLE)
		writeU32(writer, entryCount)
		for key, child in pairs(value) do
			encodeValue(writer, key, limits, depth + 1, path .. "[key]", state)
			encodeValue(writer, child, limits, depth + 1, path .. "." .. tostring(key), state)
		end
	elseif valueType == "Vector2" then
		writeU8(writer, TAG_VECTOR2)
		writeF32(writer, value.X)
		writeF32(writer, value.Y)
	elseif valueType == "Vector3" then
		writeU8(writer, TAG_VECTOR3)
		writeF32(writer, value.X)
		writeF32(writer, value.Y)
		writeF32(writer, value.Z)
	elseif valueType == "CFrame" then
		writeU8(writer, TAG_CFRAME)
		writeF32(writer, value.X)
		writeF32(writer, value.Y)
		writeF32(writer, value.Z)
		writeF32(writer, value.R00)
		writeF32(writer, value.R01)
		writeF32(writer, value.R02)
		writeF32(writer, value.R10)
		writeF32(writer, value.R11)
		writeF32(writer, value.R12)
		writeF32(writer, value.R20)
		writeF32(writer, value.R21)
		writeF32(writer, value.R22)
	elseif valueType == "Color3" then
		writeU8(writer, TAG_COLOR3)
		writeF32(writer, value.R)
		writeF32(writer, value.G)
		writeF32(writer, value.B)
	elseif valueType == "UDim" then
		writeU8(writer, TAG_UDIM)
		writeF32(writer, value.Scale)
		writeI32(writer, value.Offset)
	elseif valueType == "UDim2" then
		writeU8(writer, TAG_UDIM2)
		writeF32(writer, value.X.Scale)
		writeI32(writer, value.X.Offset)
		writeF32(writer, value.Y.Scale)
		writeI32(writer, value.Y.Offset)
	else
		error(("%s: type %s is not supported by the binary serializer"):format(path, valueType), 0)
	end
end

function Serializer.Encode(value: any, overrides: Limits?): string
	local limits = resolveLimits(overrides)
	local initialCapacity = math.max(1, math.min(256, limits.MaxBytes))
	local writer: Writer = {
		buffer = buffer.create(initialCapacity),
		size = 0,
		capacity = initialCapacity,
		maxBytes = limits.MaxBytes,
	}
	local state: EncoderState = { entries = 0 }
	encodeValue(writer, value, limits, 1, "payload", state)
	return buffer.readstring(writer.buffer, 0, writer.size)
end

type Reader = {
	buffer: buffer,
	position: number,
	length: number,
	limits: ResolvedLimits,
	entries: number,
}

local function requireBytes(reader: Reader, count: number)
	if reader.position + count > reader.length then
		error("truncated serialized payload", 0)
	end
end

local function readU8(reader: Reader): number
	requireBytes(reader, 1)
	local value = buffer.readu8(reader.buffer, reader.position)
	reader.position += 1
	return value
end

local function readU32(reader: Reader): number
	requireBytes(reader, 4)
	local value = buffer.readu32(reader.buffer, reader.position)
	reader.position += 4
	return value
end

local function readF32(reader: Reader): number
	requireBytes(reader, 4)
	local value = buffer.readf32(reader.buffer, reader.position)
	reader.position += 4
	return value
end

local function readF64(reader: Reader): number
	requireBytes(reader, 8)
	local value = buffer.readf64(reader.buffer, reader.position)
	reader.position += 8
	return value
end

local function readI32(reader: Reader): number
	requireBytes(reader, 4)
	local value = buffer.readi32(reader.buffer, reader.position)
	reader.position += 4
	return value
end

local function readRaw(reader: Reader, count: number): string
	requireBytes(reader, count)
	local value = buffer.readstring(reader.buffer, reader.position, count)
	reader.position += count
	return value
end

local function decodeValue(reader: Reader, depth: number): any
	local limits = reader.limits
	if depth > limits.MaxDepth then
		error("serialized payload exceeds the maximum depth", 0)
	end
	local tag = readU8(reader)

	if tag == TAG_NIL then
		return nil
	elseif tag == TAG_FALSE then
		return false
	elseif tag == TAG_TRUE then
		return true
	elseif tag == TAG_NUMBER then
		return readF64(reader)
	elseif tag == TAG_STRING then
		local length = readU32(reader)
		if length > limits.MaxStringLength then
			error("serialized string exceeds MaxStringLength", 0)
		end
		return readRaw(reader, length)
	elseif tag == TAG_TABLE then
		local count = readU32(reader)
		if count > limits.MaxEntries then
			error("serialized table exceeds MaxEntries", 0)
		end
		if reader.position + count * 2 > reader.length then
			error("truncated serialized table", 0)
		end
		reader.entries += count
		if reader.entries > limits.MaxEntries then
			error("serialized payload exceeds MaxEntries", 0)
		end
		local result = {}
		for _ = 1, count do
			local key = decodeValue(reader, depth + 1)
			local keyType = typeof(key)
			if keyType ~= "string" and keyType ~= "number" then
				error("serialized table contains an unsupported key", 0)
			end
			if key ~= key or key == math.huge or key == -math.huge then
				error("serialized table contains a non-finite key", 0)
			end
			result[key] = decodeValue(reader, depth + 1)
		end
		return result
	elseif tag == TAG_VECTOR2 then
		return Vector2.new(readF32(reader), readF32(reader))
	elseif tag == TAG_VECTOR3 then
		return Vector3.new(readF32(reader), readF32(reader), readF32(reader))
	elseif tag == TAG_CFRAME then
		return CFrame.new(
			readF32(reader), readF32(reader), readF32(reader),
			readF32(reader), readF32(reader), readF32(reader),
			readF32(reader), readF32(reader), readF32(reader),
			readF32(reader), readF32(reader), readF32(reader)
		)
	elseif tag == TAG_COLOR3 then
		return Color3.new(readF32(reader), readF32(reader), readF32(reader))
	elseif tag == TAG_UDIM then
		return UDim.new(readF32(reader), readI32(reader))
	elseif tag == TAG_UDIM2 then
		return UDim2.new(readF32(reader), readI32(reader), readF32(reader), readI32(reader))
	end

	error(("unknown serialization tag %d"):format(tag), 0)
end

function Serializer.Decode(binary: any, overrides: Limits?): (any, string?)
	if type(binary) ~= "string" then
		return nil, "serialized payload must be a string"
	end
	local limits = resolveLimits(overrides)
	if #binary > limits.MaxBytes then
		return nil, "serialized payload exceeds the byte limit"
	end
	if #binary == 0 then
		return nil, "serialized payload is empty"
	end
	local reader: Reader = {
		buffer = buffer.fromstring(binary),
		position = 0,
		length = #binary,
		limits = limits,
		entries = 0,
	}
	local ok, result = pcall(function()
		local value = decodeValue(reader, 1)
		if reader.position ~= reader.length then
			error("serialized payload has trailing bytes", 0)
		end
		return value
	end)
	if not ok then
		return nil, tostring(result)
	end
	return result, nil
end

-- Cheap approximate byte size used for batching budgets. Never throws and
-- never walks more than roughly maxBytes worth of entries.
function Serializer.Measure(value: any, maxBytes: number?): number
	local cap = maxBytes or DEFAULTS.MaxBytes
	local bytes = 0
	local stack: { { any } } = { { value } }
	local stackSize = 1
	local visited: { [any]: boolean } = {}

	while stackSize > 0 and bytes < cap do
		local frame = stack[stackSize]
		stack[stackSize] = nil
		stackSize -= 1
		local current = frame[1]
		if current ~= nil then
			local valueType = typeof(current)
			if valueType == "number" then
				bytes += 8
			elseif valueType == "string" then
				bytes += #current
			elseif valueType == "boolean" then
				bytes += 1
			elseif valueType == "table" then
				if not visited[current] then
					visited[current] = true
					bytes += 1
					for key, child in pairs(current) do
						local keyValue: any = key
						local keyType = typeof(keyValue)
						if keyType == "string" then
							bytes += #keyValue
						else
							bytes += 8
						end
						bytes += 1
						stackSize += 1
						stack[stackSize] = { child }
						if bytes >= cap then
							break
						end
					end
				end
			else
				bytes += NATIVE_MEASURE_SIZES[valueType] or 8
			end
		end
	end

	return math.min(bytes, cap)
end

type State = {
	_enabled: boolean,
	_limits: Limits,
}

export type Serializer = State & {
	IsEnabled: (self: Serializer) -> boolean,
	GetLimits: (self: Serializer) -> Limits,
	Encode: (self: Serializer, value: any) -> string,
	Decode: (self: Serializer, binary: any) -> (any, string?),
}

local SerializerClass = {}
SerializerClass.__index = SerializerClass

function Serializer.new(config: Config?): Serializer
	local self: Serializer = setmetatable({
		_enabled = config ~= nil and config.Enabled == true,
		_limits = (config and config.Limits) or {},
	}, SerializerClass) :: any
	return self
end

local function isEnabled(self: Serializer): boolean
	return self._enabled
end
SerializerClass.IsEnabled = isEnabled

local function getLimits(self: Serializer): Limits
	return self._limits
end
SerializerClass.GetLimits = getLimits

local function encodeInstance(self: Serializer, value: any): string
	return Serializer.Encode(value, self._limits)
end
SerializerClass.Encode = encodeInstance

local function decodeInstance(self: Serializer, binary: any): (any, string?)
	return Serializer.Decode(binary, self._limits)
end
SerializerClass.Decode = decodeInstance

return Serializer
