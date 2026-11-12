--!strict
-- Runtime validation for untrusted payloads: composable schemas plus a cheap
-- structural walk that enforces byte and depth limits before any expensive
-- processing happens.

local Validator = {}

export type Schema = { [string]: any }

export type PayloadLimits = {
	MaxBytes: number,
	MaxDepth: number,
}

local NATIVE_SIZES: { [string]: number } = {
	Vector2 = 8,
	Vector3 = 12,
	CFrame = 48,
	Color3 = 12,
	UDim = 8,
	UDim2 = 16,
	Instance = 8,
	EnumItem = 4,
}

Validator.Any = table.freeze({ Kind = "Any" })
Validator.Boolean = table.freeze({ Kind = "Boolean" })
Validator.Vector3 = table.freeze({ Kind = "Vector3" })

Validator.Number = setmetatable({ Kind = "Number" }, {
	__call = function(_, options: any)
		return { Kind = "Number", Options = options }
	end,
})

Validator.String = setmetatable({ Kind = "String" }, {
	__call = function(_, options: any)
		return { Kind = "String", Options = options }
	end,
})

Validator.Instance = setmetatable({ Kind = "Instance" }, {
	__call = function(_, className: string?)
		return { Kind = "Instance", ClassName = className }
	end,
})

function Validator.Table(options: any): Schema
	return { Kind = "Table", Options = options }
end

function Validator.Array(elementSchema: Schema, options: any?): Schema
	return { Kind = "Array", Element = elementSchema, Options = options }
end

function Validator.Optional(inner: Schema): Schema
	return { Kind = "Optional", Inner = inner }
end

local function describeType(value: any): string
	return typeof(value)
end

local function withPath(path: string, message: string): string
	return path .. ": " .. message
end

local function validateValue(value: any, schema: Schema, path: string): (boolean, string?)
	local kind: any = schema.Kind

	if kind == "Optional" then
		if value == nil then
			return true, nil
		end
		return validateValue(value, schema.Inner, path)
	elseif kind == "Any" then
		return true, nil
	elseif value == nil then
		return false, withPath(path, "expected " .. tostring(kind) .. ", got nil")
	end

	if kind == "Boolean" then
		if type(value) ~= "boolean" then
			return false, withPath(path, "expected boolean, got " .. describeType(value))
		end
		return true, nil
	elseif kind == "Number" then
		if type(value) ~= "number" then
			return false, withPath(path, "expected number, got " .. describeType(value))
		end
		if value ~= value then
			return false, withPath(path, "number must be finite")
		end
		local options: any = schema.Options
		if options then
			if options.Min ~= nil and value < options.Min then
				return false, withPath(path, "number below minimum " .. tostring(options.Min))
			end
			if options.Max ~= nil and value > options.Max then
				return false, withPath(path, "number above maximum " .. tostring(options.Max))
			end
			if options.Integer and value % 1 ~= 0 then
				return false, withPath(path, "expected integer")
			end
		end
		return true, nil
	elseif kind == "String" then
		if type(value) ~= "string" then
			return false, withPath(path, "expected string, got " .. describeType(value))
		end
		local options: any = schema.Options
		if options then
			if options.MinLength ~= nil and #value < options.MinLength then
				return false, withPath(path, "string shorter than " .. tostring(options.MinLength))
			end
			if options.MaxLength ~= nil and #value > options.MaxLength then
				return false, withPath(path, "string longer than " .. tostring(options.MaxLength))
			end
		end
		return true, nil
	elseif kind == "Instance" then
		if typeof(value) ~= "Instance" then
			return false, withPath(path, "expected Instance, got " .. describeType(value))
		end
		local className = schema.ClassName
		if className then
			local ok, result = pcall(function()
				return value:IsA(className)
			end)
			if not ok or not result then
				return false, withPath(path, "expected instance of class " .. tostring(className))
			end
		end
		return true, nil
	elseif kind == "Vector3" then
		if typeof(value) ~= "Vector3" then
			return false, withPath(path, "expected Vector3, got " .. describeType(value))
		end
		return true, nil
	elseif kind == "Table" then
		if type(value) ~= "table" then
			return false, withPath(path, "expected table, got " .. describeType(value))
		end
		local options: any = schema.Options or {}
		local fields: any = options.Fields or {}
		for fieldName, fieldSchema in pairs(fields) do
			local ok, err = validateValue(value[fieldName], fieldSchema :: any, path .. "." .. tostring(fieldName))
			if not ok then
				return false, err
			end
		end
		if not options.AllowUnknown then
			for key in pairs(value) do
				if fields[key] == nil then
					return false, withPath(path, "unexpected field " .. tostring(key))
				end
			end
		end
		return true, nil
	elseif kind == "Array" then
		if type(value) ~= "table" then
			return false, withPath(path, "expected array, got " .. describeType(value))
		end
		local length = #value
		local options: any = schema.Options or {}
		if options.MinLength ~= nil and length < options.MinLength then
			return false, withPath(path, "array shorter than " .. tostring(options.MinLength))
		end
		if options.MaxLength ~= nil and length > options.MaxLength then
			return false, withPath(path, "array longer than " .. tostring(options.MaxLength))
		end
		local entries = 0
		for key in pairs(value) do
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
				return false, withPath(path, "array contains a non-index key")
			end
			entries += 1
		end
		if entries ~= length then
			return false, withPath(path, "array is sparse")
		end
		for index = 1, length do
			local ok, err = validateValue(value[index], schema.Element, path .. "[" .. tostring(index) .. "]")
			if not ok then
				return false, err
			end
		end
		return true, nil
	end

	return false, withPath(path, "unknown schema kind " .. tostring(kind))
end

function Validator.Validate(value: any, schema: Schema, path: string?): (boolean, string?)
	return validateValue(value, schema, path or "payload")
end

-- Iterative structural check: rejects unsupported types, non-finite numbers,
-- exotic keys, cyclic/shared references, and payloads exceeding the byte or
-- depth budget. Iterative so hostile nesting cannot overflow the stack.
function Validator.CheckPayload(value: any, limits: PayloadLimits): (boolean, string?)
	local bytes = 0
	local stack: { { any } } = { { value, 1 } }
	local stackSize = 1
	local visited: { [any]: boolean } = {}

	while stackSize > 0 do
		local frame = stack[stackSize]
		stack[stackSize] = nil
		stackSize -= 1
		local current = frame[1]
		local depth = frame[2]

		if current ~= nil then
			local valueType = typeof(current)
			if valueType == "number" then
				if current ~= current or current == math.huge or current == -math.huge then
					return false, "payload contains a non-finite number"
				end
				bytes += 8
			elseif valueType == "string" then
				bytes += #current
			elseif valueType == "boolean" then
				bytes += 1
			elseif valueType == "table" then
				if depth > limits.MaxDepth then
					return false, "payload exceeds the maximum depth"
				end
				if visited[current] then
					return false, "payload contains a cyclic or shared table reference"
				end
				visited[current] = true
				bytes += 1
				for key, child in pairs(current) do
					local keyValue: any = key
					local childValue: any = child
					local keyType = typeof(keyValue)
					if keyType == "string" then
						bytes += #keyValue
					elseif keyType == "number" then
						if keyValue ~= keyValue or keyValue == math.huge or keyValue == -math.huge then
							return false, "payload contains a non-finite table key"
						end
						bytes += 8
					else
						return false, "payload contains an unsupported table key type: " .. keyType
					end
					bytes += 1
					if bytes > limits.MaxBytes then
						return false, "payload exceeds the byte limit"
					end
					stackSize += 1
					stack[stackSize] = { childValue, depth + 1 }
				end
			elseif valueType == "buffer" then
				bytes += buffer.len(current)
			else
				local nativeSize = NATIVE_SIZES[valueType]
				if nativeSize then
					bytes += nativeSize
				else
					return false, "payload contains an unsupported value type: " .. valueType
				end
			end
		end

		if bytes > limits.MaxBytes then
			return false, "payload exceeds the byte limit"
		end
	end

	return true, nil
end

return Validator
