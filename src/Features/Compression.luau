--!strict
-- Pluggable, opt-in compression. The built-in RLE codec is intentionally simple
-- and fully tested; compression is only applied when the encoded result is
-- meaningfully smaller than the original, so incompressible payloads pay no
-- bandwidth penalty.

local Compression = {}
Compression.__index = Compression

export type Codec = {
	Name: string,
	Encode: (value: string) -> string,
	Decode: (value: string, maxOutputBytes: number?) -> (string?, string?),
}

-- Block format:
--   0x00, length (1..255), bytes...   literal run
--   0x01, count (2..255), byte        repeated run
local function rleEncode(value: string): string
	local parts = {}
	local length = #value
	local index = 1

	while index <= length do
		local byte = string.byte(value, index) :: number
		local runEnd = index
		while runEnd + 1 <= length
			and runEnd - index + 1 < 255
			and string.byte(value, runEnd + 1) == byte
		do
			runEnd += 1
		end
		local runLength = runEnd - index + 1

		if runLength >= 4 then
			table.insert(parts, "\1" .. string.char(runLength, byte))
			index = runEnd + 1
		else
			local literalStart = index
			local cursor = index
			while cursor <= length and (cursor - literalStart) < 255 do
				local candidate = string.byte(value, cursor) :: number
				local repeated = 1
				while repeated < 4
					and cursor + repeated <= length
					and string.byte(value, cursor + repeated) == candidate
				do
					repeated += 1
				end
				if repeated >= 4 and cursor > literalStart then
					break
				end
				cursor += 1
			end
			local literalLength = cursor - literalStart
			table.insert(parts, "\0" .. string.char(literalLength) .. string.sub(value, literalStart, cursor - 1))
			index = cursor
		end
	end

	return table.concat(parts)
end

local function rleDecode(value: string, maxOutputBytes: number?): (string?, string?)
	if type(value) ~= "string" then
		return nil, "compressed payload must be a string"
	end
	local outputLimit = maxOutputBytes or 1048576
	local length = #value
	local parts = {}
	local outputBytes = 0
	local index = 1

	while index <= length do
		local control = string.byte(value, index) :: number
		index += 1

		if control == 0 then
			if index > length then
				return nil, "truncated literal header"
			end
			local count = string.byte(value, index) :: number
			index += 1
			if count == 0 then
				return nil, "invalid literal length"
			end
			if index + count - 1 > length then
				return nil, "truncated literal payload"
			end
			outputBytes += count
			if outputBytes > outputLimit then
				return nil, "decompressed payload exceeds the byte limit"
			end
			table.insert(parts, string.sub(value, index, index + count - 1))
			index += count
		elseif control == 1 then
			if index + 1 > length then
				return nil, "truncated repeat header"
			end
			local count = string.byte(value, index) :: number
			local byte = string.byte(value, index + 1) :: number
			index += 2
			if count < 2 then
				return nil, "invalid repeat length"
			end
			outputBytes += count
			if outputBytes > outputLimit then
				return nil, "decompressed payload exceeds the byte limit"
			end
			table.insert(parts, string.rep(string.char(byte), count))
		else
			return nil, "invalid block control byte"
		end
	end

	return table.concat(parts), nil
end

local RLE: any = {
	Name = "rle",
	Encode = rleEncode,
	Decode = rleDecode,
}
Compression.RLE = table.freeze(RLE)

export type Config = {
	Enabled: boolean?,
	Threshold: number?,
	MinSavingsRatio: number?,
	MaxDecompressedBytes: number?,
	Codec: (Codec | string)?,
}

local DEFAULT_CODEC = "rle"
local DEFAULT_THRESHOLD = 256
local DEFAULT_SAVINGS_RATIO = 0.9
local DEFAULT_MAX_DECOMPRESSED = 1048576

local function resolveCodec(configured: (Codec | string)?): Codec
	if configured == nil or configured == DEFAULT_CODEC then
		return RLE
	end
	if type(configured) == "string" then
		error(("Unknown compression codec %q"):format(configured), 3)
	end
	local codec: any = configured
	if type(codec) ~= "table"
		or type(codec.Name) ~= "string"
		or type(codec.Encode) ~= "function"
		or type(codec.Decode) ~= "function"
	then
		error("Compression codec must provide Name, Encode and Decode", 3)
	end
	return codec :: Codec
end

type State = {
	_enabled: boolean,
	_threshold: number,
	_minSavingsRatio: number,
	_maxDecompressedBytes: number,
	_codec: Codec,
}

export type Compression = State & {
	GetCodecName: (self: Compression) -> string,
	Compress: (self: Compression, value: string) -> (string, boolean),
	Decompress: (self: Compression, value: string) -> (string?, string?),
}

function Compression.new(config: Config?): Compression
	local self: Compression = setmetatable({
		_enabled = config ~= nil and config.Enabled == true,
		_threshold = (config and config.Threshold) or DEFAULT_THRESHOLD,
		_minSavingsRatio = (config and config.MinSavingsRatio) or DEFAULT_SAVINGS_RATIO,
		_maxDecompressedBytes = (config and config.MaxDecompressedBytes) or DEFAULT_MAX_DECOMPRESSED,
		_codec = resolveCodec(config and config.Codec),
	}, Compression) :: any
	return self
end

local function getCodecName(self: Compression): string
	return self._codec.Name
end
Compression.GetCodecName = getCodecName

-- Returns (payloadToSend, wasCompressed). The caller only sets the compressed
-- wire flag when wasCompressed is true.
local function compress(self: Compression, value: string): (string, boolean)
	if not self._enabled or #value < self._threshold then
		return value, false
	end
	local ok, encoded = pcall(self._codec.Encode, value)
	if not ok or type(encoded) ~= "string" then
		if not ok then
			warn("Compression codec error: " .. tostring(encoded))
		end
		return value, false
	end
	if #encoded <= #value * self._minSavingsRatio then
		return encoded, true
	end
	return value, false
end
Compression.Compress = compress

local function decompress(self: Compression, value: string): (string?, string?)
	local ok, result, err = pcall(self._codec.Decode, value, self._maxDecompressedBytes)
	if not ok then
		return nil, tostring(result)
	end
	if type(result) ~= "string" then
		return nil, err or "compression codec failed to decode"
	end
	return result, err
end
Compression.Decompress = decompress

return Compression
