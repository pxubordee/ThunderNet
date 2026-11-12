--!nocheck
-- Loads module sources inside a sandboxed environment that injects the fake
-- Roblox API. Used only by the CLI runners.

local ModuleLoader = {}
ModuleLoader.__index = ModuleLoader

local STANDARD_GLOBALS = _G

function ModuleLoader.new(shim, sources)
	return setmetatable({
		shim = shim,
		sources = sources,
		cache = {},
		loading = {},
	}, ModuleLoader)
end

function ModuleLoader:_makeEnvironment(scriptInstance)
	local shim = self.shim
	local loader = self
	local environment = {
		script = scriptInstance,
		game = shim.game,
		Instance = shim.Instance,
		task = shim.task,
		typeof = shim.typeof,
		os = shim.os,
		warn = shim.warn,
		Vector2 = shim.Vector2,
		Vector3 = shim.Vector3,
		CFrame = shim.CFrame,
		Color3 = shim.Color3,
		UDim = shim.UDim,
		UDim2 = shim.UDim2,
		__TNTEST_SHIM = shim,
	}
	environment.require = function(target)
		return loader:Require(target)
	end
	return setmetatable(environment, { __index = STANDARD_GLOBALS })
end

function ModuleLoader:Require(instance)
	if type(instance) ~= "table" or instance._source == nil then
		error(("ModuleLoader: require expects a ModuleScript with source, got %s"):format(tostring(instance)), 2)
	end
	local cached = self.cache[instance]
	if cached ~= nil then
		return cached
	end
	if self.loading[instance] then
		error("ModuleLoader: cyclic require detected at " .. tostring(instance._path), 0)
	end
	self.loading[instance] = true
	local chunk, compileError = loadstring(instance._source, "@" .. tostring(instance._path))
	if not chunk then
		self.loading[instance] = nil
		error(("ModuleLoader: compile error in %s: %s"):format(tostring(instance._path), tostring(compileError)), 0)
	end
	setfenv(chunk, self:_makeEnvironment(instance))
	local result = table.pack(pcall(chunk))
	self.loading[instance] = nil
	if not result[1] then
		error(("ModuleLoader: runtime error loading %s: %s"):format(tostring(instance._path), tostring(result[2])), 0)
	end
	local value = result[2]
	if value == nil then
		value = true
	end
	self.cache[instance] = value
	return value
end

return ModuleLoader
