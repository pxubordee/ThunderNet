--!nonstrict
-- In-Studio test runner. Requires the Rojo-synced project (ThunderNet in
-- ReplicatedStorage, this folder under ServerScriptService).
-- The Luau CLI runner (scripts/test.sh) is the primary, deterministic suite;
-- this runner executes synchronous specs inside Roblox.

local TestHarness = require(script.Parent.Support.TestHarness)

for _, spec in ipairs(script.Parent.Spec:GetChildren()) do
	if spec:IsA("ModuleScript") then
		local ok, err = pcall(require, spec)
		if not ok then
			warn(("Failed to load spec %s: %s"):format(spec.Name, tostring(err)))
		end
	end
end

local passed, failed, skipped = 0, 0, 0
for _, suite in ipairs(TestHarness.getSuites()) do
	for _, test in ipairs(suite.Tests) do
		if test.Skip then
			skipped = skipped + 1
		else
			local ok, err = pcall(test.Body)
			if ok then
				passed = passed + 1
			else
				failed = failed + 1
				warn(("FAIL %s > %s: %s"):format(suite.Name, test.Name, tostring(err)))
			end
		end
	end
end

print(("[ThunderNet Tests] %d passed, %d failed, %d skipped"):format(passed, failed, skipped))
