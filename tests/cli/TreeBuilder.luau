--!nocheck
-- Builds a simulated Roblox instance tree from embedded Luau sources.
local TreeBuilder = {}

local function splitFile(file)
	local className = "ModuleScript"
	local name = file
	if file:sub(-12) == ".server.luau" then
		className = "Script"
		name = file:sub(1, -13)
	elseif file:sub(-12) == ".client.luau" then
		className = "Script"
		name = file:sub(1, -13)
	elseif file:sub(-5) == ".luau" then
		name = file:sub(1, -6)
	end
	return name, className
end

local function buildNode(shim, sources, prefix, name, parent)
	local hasInit = sources[prefix .. "/init.luau"] ~= nil
	local node = shim.Instance.new(hasInit and "ModuleScript" or "Folder", name)
	if hasInit then
		node._source = sources[prefix .. "/init.luau"]
		node._path = prefix .. "/init.luau"
	end
	node.Parent = parent

	local directories = {}
	local files = {}
	for path in pairs(sources) do
		if path:sub(1, #prefix + 1) == prefix .. "/" then
			local rest = path:sub(#prefix + 2)
			local directory = rest:match("^([^/]+)/")
			if directory then
				directories[directory] = true
			elseif rest ~= "init.luau" then
				files[rest] = path
			end
		end
	end

	local sortedDirectories = {}
	for directory in pairs(directories) do
		table.insert(sortedDirectories, directory)
	end
	table.sort(sortedDirectories)
	for _, directory in ipairs(sortedDirectories) do
		buildNode(shim, sources, prefix .. "/" .. directory, directory, node)
	end

	local sortedFiles = {}
	for file in pairs(files) do
		table.insert(sortedFiles, file)
	end
	table.sort(sortedFiles)
	for _, file in ipairs(sortedFiles) do
		local fileName, className = splitFile(file)
		local child = shim.Instance.new(className, fileName)
		child._source = sources[files[file]]
		child._path = files[file]
		child.Parent = node
	end

	return node
end

function TreeBuilder.build(shim, sources, prefix, name, parent)
	return buildNode(shim, sources, prefix, name, parent)
end

return TreeBuilder
