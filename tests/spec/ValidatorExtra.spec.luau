--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Validator = require(ThunderNetFolder.Security.Validator)

local describe, it = TestHarness.describe, TestHarness.it
local V = Validator

describe("Validator extra schemas", function()
	it("validates literal values", function()
		Expect(V.Validate("prod", V.Literal("prod"))):toBeTruthy()
		Expect(V.Validate("dev", V.Literal("prod"))):toBeFalsy()
		Expect(V.Validate(7, V.Literal(7))):toBeTruthy()
		Expect(V.Validate(8, V.Literal(7))):toBeFalsy()
	end)

	it("accepts any matching schema from OneOf", function()
		local schema = V.OneOf({ V.String, V.Number })
		Expect(V.Validate("hello", schema)):toBeTruthy()
		Expect(V.Validate(12, schema)):toBeTruthy()
		Expect(V.Validate(true, schema)):toBeFalsy()
		Expect(V.Validate({}, schema)):toBeFalsy()
	end)

	it("validates map keys and values", function()
		local schema = V.Map(V.String, V.Number)
		Expect(V.Validate({ A = 1, B = 2 }, schema)):toBeTruthy()
		Expect(V.Validate({ A = "bad" }, schema)):toBeFalsy()
		Expect(V.Validate({ [1] = 2 }, schema)):toBeFalsy()
		Expect(V.Validate("not a table", schema)):toBeFalsy()

		local numericKeys = V.Map(V.Number, V.String)
		Expect(V.Validate({ [1] = "a", [2] = "b" }, numericKeys)):toBeTruthy()
		Expect(V.Validate({ A = "a" }, numericKeys)):toBeFalsy()
	end)
end)
