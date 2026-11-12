--!nonstrict
-- Minimal dependency-free test harness. Works both under Roblox and under the
-- Luau CLI sandbox loader.

local TestHarness = {}

local suites = {}
local currentSuite = nil

function TestHarness.describe(name, body)
	local suite = {
		Name = name,
		Tests = {},
	}
	table.insert(suites, suite)
	local previous = currentSuite
	currentSuite = suite
	local ok, result = pcall(body)
	currentSuite = previous
	if not ok then
		error(("Error while registering suite %q: %s"):format(name, tostring(result)), 0)
	end
	return suite
end

function TestHarness.it(name, body)
	assert(currentSuite ~= nil, "it() must be called inside describe()")
	table.insert(currentSuite.Tests, {
		Name = name,
		Body = body,
		Skip = false,
	})
end

function TestHarness.itSkip(name, body, reason)
	assert(currentSuite ~= nil, "itSkip() must be called inside describe()")
	table.insert(currentSuite.Tests, {
		Name = name,
		Body = body,
		Skip = true,
		Reason = reason,
	})
end

function TestHarness.getSuites()
	return suites
end

function TestHarness.reset()
	suites = {}
	currentSuite = nil
end

return TestHarness
