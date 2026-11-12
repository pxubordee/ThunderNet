--!nonstrict
-- Bridges specs to the runtime they execute in.
-- Under the Luau CLI runner a simulated Roblox environment drives time and
-- remote delivery deterministically; under Roblox, real task timing is used.

local shim = __TNTEST_SHIM

local Runtime = {
	available = shim ~= nil,
}

if shim then
	Runtime.now = function()
		return shim.now()
	end

	Runtime.advance = function(seconds)
		shim.advance(seconds)
	end

	Runtime.advanceFrames = function(count)
		shim.advanceFrames(count)
	end

	Runtime.createPlayer = function(name)
		return shim.createPlayer(name)
	end

	Runtime.removePlayer = function(player)
		shim.removePlayer(player)
	end

	Runtime.setClient = function(player)
		shim.setClientContext(player)
	end

	Runtime.clearClient = function()
		shim.setClientContext(nil)
	end

	Runtime.withClient = function(player, callback)
		return shim.withClient(player, callback)
	end
else
	Runtime.now = function()
		return os.clock()
	end

	Runtime.advance = function(seconds)
		task.wait(seconds)
	end

	Runtime.advanceFrames = function()
		task.wait()
	end

	Runtime.createPlayer = function()
		error("Simulated players require the Luau CLI test runner", 2)
	end

	Runtime.removePlayer = function()
		error("Simulated players require the Luau CLI test runner", 2)
	end

	Runtime.setClient = function()
		error("Simulated clients require the Luau CLI test runner", 2)
	end

	Runtime.clearClient = function() end

	Runtime.withClient = function()
		error("Simulated clients require the Luau CLI test runner", 2)
	end
end

-- Yields the calling test thread until predicate() is true or timeout elapses.
function Runtime.waitFor(predicate, timeout)
	local deadline = Runtime.now() + (timeout or 2)
	while not predicate() do
		if Runtime.now() > deadline then
			return false
		end
		task.wait(0)
	end
	return true
end

return Runtime
