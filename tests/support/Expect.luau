--!nonstrict
-- Small assertion library used by every spec.

local Expect = {}

local Expectation = {}
Expectation.__index = Expectation

local function deepEqual(a, b, seen)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	seen = seen or {}
	if seen[a] == b then
		return true
	end
	seen[a] = b
	for key, value in pairs(a) do
		if not deepEqual(value, b[key], seen) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function describeValue(value)
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

function Expect.new(value, label)
	return setmetatable({
		value = value,
		label = label or "value",
	}, Expectation)
end

function Expectation:toBe(expected)
	if self.value ~= expected then
		error(
			("%s: expected %s but got %s"):format(self.label, describeValue(expected), describeValue(self.value)),
			2
		)
	end
	return self
end

function Expectation:toNotBe(expected)
	if self.value == expected then
		error(("%s: expected value different from %s"):format(self.label, describeValue(expected)), 2)
	end
	return self
end

function Expectation:toEqual(expected)
	if not deepEqual(self.value, expected) then
		error(("%s: expected deep equality with %s but got %s"):format(
			self.label,
			describeValue(expected),
			describeValue(self.value)
		), 2)
	end
	return self
end

function Expectation:toBeTruthy()
	if not self.value then
		error(("%s: expected truthy value, got %s"):format(self.label, describeValue(self.value)), 2)
	end
	return self
end

function Expectation:toBeFalsy()
	if self.value then
		error(("%s: expected falsy value, got %s"):format(self.label, describeValue(self.value)), 2)
	end
	return self
end

function Expectation:toBeNil()
	if self.value ~= nil then
		error(("%s: expected nil, got %s"):format(self.label, describeValue(self.value)), 2)
	end
	return self
end

function Expectation:toBeNear(expected, epsilon)
	if math.abs(self.value - expected) > (epsilon or 1e-6) then
		error(("%s: expected %s +/- %s, got %s"):format(
			self.label,
			tostring(expected),
			tostring(epsilon or 1e-6),
			tostring(self.value)
		), 2)
	end
	return self
end

function Expectation:toHaveLength(expected)
	local length = self.value and #self.value
	if length ~= expected then
		error(("%s: expected length %d, got %s"):format(self.label, expected, tostring(length)), 2)
	end
	return self
end

function Expectation:toInclude(substring)
	if type(self.value) ~= "string" then
		error(("%s: toInclude requires a string"):format(self.label), 2)
	end
	if not string.find(self.value, substring, 1, true) then
		error(("%s: expected string to include %q but got %q"):format(
			self.label,
			tostring(substring),
			tostring(self.value)
		), 2)
	end
	return self
end

function Expectation:toContain(expected)
	if type(self.value) ~= "table" then
		error(("%s: toContain requires a table"):format(self.label), 2)
	end
	for _, value in ipairs(self.value) do
		if value == expected then
			return self
		end
	end
	error(("%s: expected collection to contain %s"):format(self.label, describeValue(expected)), 2)
end

function Expectation:toThrow()
	if type(self.value) ~= "function" then
		error(("%s: toThrow requires a function"):format(self.label), 2)
	end
	local ok = pcall(self.value)
	if ok then
		error(("%s: expected function to throw, but it returned normally"):format(self.label), 2)
	end
	return self
end

function Expectation:toNotThrow()
	if type(self.value) ~= "function" then
		error(("%s: toNotThrow requires a function"):format(self.label), 2)
	end
	local ok, err = pcall(self.value)
	if not ok then
		error(("%s: expected function not to throw, but it threw: %s"):format(self.label, tostring(err)), 2)
	end
	return self
end

function Expect.create(value, label)
	return Expect.new(value, label)
end

setmetatable(Expect, {
	__call = function(_, value, label)
		return Expect.new(value, label)
	end,
})

return Expect
