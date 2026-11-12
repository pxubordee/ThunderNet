--!strict
-- Cleanup utility that tracks functions, connections, instances and anything
-- with a Destroy method. Cleans in reverse insertion order.

local Janitor = {}
Janitor.__index = Janitor

type State = {
	_items: { any },
	_destroyed: boolean,
}

export type Janitor = State & {
	Add: (self: Janitor, item: any) -> any,
	Remove: (self: Janitor, item: any) -> boolean,
	GetCount: (self: Janitor) -> number,
	Cleanup: (self: Janitor) -> (),
	Destroy: (self: Janitor) -> (),
}

function Janitor.new(): Janitor
	local self: Janitor = setmetatable({
		_items = {} :: { any },
		_destroyed = false,
	}, Janitor) :: any
	return self
end

local function cleanupItem(item: any)
	if type(item) == "function" then
		local callback: any = item
		callback()
	elseif typeof(item) == "Instance" then
		item:Destroy()
	elseif type(item) == "table" or typeof(item) == "RBXScriptConnection" then
		local disconnect = item.Disconnect
		if type(disconnect) == "function" then
			disconnect(item)
		else
			local destroy = item.Destroy
			if type(destroy) == "function" then
				destroy(item)
			else
				error("Janitor item has neither Disconnect nor Destroy", 0)
			end
		end
	else
		error("Janitor cannot clean up value of type " .. typeof(item), 0)
	end
end

local function isCleanable(item: any): boolean
	if type(item) == "function" then
		return true
	end
	if typeof(item) == "Instance" or typeof(item) == "RBXScriptConnection" then
		return true
	end
	if type(item) == "table" then
		return type(item.Disconnect) == "function" or type(item.Destroy) == "function"
	end
	return false
end

local function add(self: Janitor, item: any): any
	if self._destroyed then
		error("Janitor is destroyed; cannot add new items", 3)
	end
	if not isCleanable(item) then
		error("Janitor cannot track value of type " .. typeof(item), 3)
	end
	table.insert(self._items, item)
	return item
end
Janitor.Add = add

local function remove(self: Janitor, item: any): boolean
	local items = self._items
	for index = #items, 1, -1 do
		if items[index] == item then
			table.remove(items, index)
			return true
		end
	end
	return false
end
Janitor.Remove = remove

local function getCount(self: Janitor): number
	return #self._items
end
Janitor.GetCount = getCount

local function cleanup(self: Janitor)
	local items = self._items
	self._items = {}
	for index = #items, 1, -1 do
		local ok, err = pcall(cleanupItem, items[index])
		if not ok then
			warn("Janitor cleanup error: " .. tostring(err))
		end
	end
end
Janitor.Cleanup = cleanup

local function destroy(self: Janitor)
	if self._destroyed then
		return
	end
	self._destroyed = true
	cleanup(self)
end
Janitor.Destroy = destroy

return Janitor
