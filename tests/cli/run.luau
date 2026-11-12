--!nocheck
-- ThunderNet test runner for the Luau CLI.
-- Uses a simulated Roblox DataModel so the exact framework sources can be
-- exercised without Studio.

local RobloxShim = require("./RobloxShim")
local ModuleLoader = require("./ModuleLoader")
local TreeBuilder = require("./TreeBuilder")
local sources = require("./generated/AllModules")

local shim = RobloxShim.new()
local loader = ModuleLoader.new(shim, sources)

local replicatedStorage = shim.game:GetService("ReplicatedStorage")
local serverScriptService = shim.game:GetService("ServerScriptService")

TreeBuilder.build(shim, sources, "src", "ThunderNet", replicatedStorage)

local testsRoot = shim.Instance.new("Folder", "ThunderNetTests")
testsRoot.Parent = serverScriptService
TreeBuilder.build(shim, sources, "tests/support", "Support", testsRoot)
local specFolder = TreeBuilder.build(shim, sources, "tests/spec", "Spec", testsRoot)

local TestHarness = loader:Require(testsRoot.Support.TestHarness)

local specNames = {}
for _, child in ipairs(specFolder:GetChildren()) do
	table.insert(specNames, child.Name)
end
table.sort(specNames)

local loadFailures = 0
for _, name in ipairs(specNames) do
	local ok, err = pcall(function()
		loader:Require(specFolder[name])
	end)
	if not ok then
		loadFailures = loadFailures + 1
		print(("LOAD FAIL %s: %s"):format(name, tostring(err)))
	end
end

print("")
print("ThunderNet test suite (Luau CLI simulated Roblox environment)")
print(("="):rep(70))

local passed, failed, skipped = 0, 0, 0
local failureMessages = {}

for _, suite in ipairs(TestHarness.getSuites()) do
	print("")
	print("  " .. suite.Name)
	for _, test in ipairs(suite.Tests) do
		if test.Skip then
			skipped = skipped + 1
			print(("    - SKIP %s"):format(test.Name))
		else
			local ok, errors = shim.runThread(test.Body, 20)
			if ok then
				passed = passed + 1
				print(("    + PASS %s"):format(test.Name))
			else
				failed = failed + 1
				local message = ("    x FAIL %s"):format(test.Name)
				print(message)
				for _, errorMessage in ipairs(errors) do
					local firstLine = tostring(errorMessage):match("^[^\n]*") or tostring(errorMessage)
					print("        " .. firstLine)
				end
				table.insert(failureMessages, {
					Suite = suite.Name,
					Test = test.Name,
					Errors = errors,
				})
			end
		end
	end
end

print("")
print(("="):rep(70))
print(("Results: %d passed, %d failed, %d skipped, %d load failures"):format(
	passed,
	failed,
	skipped,
	loadFailures
))
print("")

if failed > 0 or loadFailures > 0 then
	for _, failure in ipairs(failureMessages) do
		print(("%s > %s"):format(failure.Suite, failure.Test))
		for _, errorMessage in ipairs(failure.Errors) do
			print(tostring(errorMessage))
		end
	end
	error(("%d test(s) failed"):format(failed + loadFailures), 0)
end
