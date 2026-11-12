--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Validator = require(ThunderNetFolder.Security.Validator)

local describe, it = TestHarness.describe, TestHarness.it
local V = Validator

describe("Validator schemas", function()
	it("validates primitives", function()
		Expect(V.Validate(5, V.Any)):toBeTruthy()
		Expect(V.Validate(nil, V.Any)):toBeTruthy()
		Expect(V.Validate(true, V.Boolean)):toBeTruthy()
		Expect(V.Validate(false, V.Boolean)):toBeTruthy()
		Expect(V.Validate(1, V.Boolean)):toBeFalsy()
		Expect(V.Validate("hi", V.String)):toBeTruthy()
		Expect(V.Validate(5, V.String)):toBeFalsy()
		Expect(V.Validate(5, V.Number)):toBeTruthy()
		Expect(V.Validate("5", V.Number)):toBeFalsy()
	end)

	it("enforces number and string constraints", function()
		Expect(V.Validate(5, V.Number({ Min = 0, Max = 10 }))):toBeTruthy()
		Expect(V.Validate(11, V.Number({ Min = 0, Max = 10 }))):toBeFalsy()
		Expect(V.Validate(-1, V.Number({ Min = 0 }))):toBeFalsy()
		Expect(V.Validate(5.5, V.Number({ Integer = true }))):toBeFalsy()
		Expect(V.Validate(5, V.Number({ Integer = true }))):toBeTruthy()
		Expect(V.Validate("abc", V.String({ MinLength = 2, MaxLength = 3 }))):toBeTruthy()
		Expect(V.Validate("abcd", V.String({ MaxLength = 3 }))):toBeFalsy()
		Expect(V.Validate("a", V.String({ MinLength = 2 }))):toBeFalsy()
	end)

	it("checks instance types", function()
		local model = Instance.new("Model")
		local part = Instance.new("Part")
		Expect(V.Validate(model, V.Instance("Model"))):toBeTruthy()
		Expect(V.Validate(part, V.Instance("Model"))):toBeFalsy()
		Expect(V.Validate(part, V.Instance)):toBeTruthy()
		Expect(V.Validate("not an instance", V.Instance)):toBeFalsy()
	end)

	it("validates table fields and rejects unknown fields by default", function()
		local schema = V.Table({
			Fields = {
				Damage = V.Number({ Min = 0 }),
				Source = V.String(),
			},
		})
		Expect(V.Validate({ Damage = 5, Source = "sword" }, schema)):toBeTruthy()
		Expect(V.Validate({ Damage = 5 }, schema)):toBeFalsy()
		Expect(V.Validate({ Damage = 5, Source = "sword", Extra = 1 }, schema)):toBeFalsy()
		Expect(V.Validate("nope", schema)):toBeFalsy()

		local permissive = V.Table({
			Fields = { Damage = V.Number() },
			AllowUnknown = true,
		})
		Expect(V.Validate({ Damage = 1, Extra = true }, permissive)):toBeTruthy()
	end)

	it("reports the failing field path", function()
		local schema = V.Table({
			Fields = {
				Inner = V.Table({ Fields = { Health = V.Number() } }),
			},
		})
		local ok, err = V.Validate({ Inner = { Health = "bad" } }, schema)
		Expect(ok):toBeFalsy()
		Expect(err):toInclude("Inner")
		Expect(err):toInclude("Health")
	end)

	it("validates arrays with limits", function()
		local schema = V.Array(V.Number({ Min = 0 }), { MaxLength = 3 })
		Expect(V.Validate({ 1, 2, 3 }, schema)):toBeTruthy()
		Expect(V.Validate({ 1, 2, 3, 4 }, schema)):toBeFalsy()
		Expect(V.Validate({ 1, -1 }, schema)):toBeFalsy()
		Expect(V.Validate({ 1, 2, key = "mixed" }, schema)):toBeFalsy()
		Expect(V.Validate("nope", schema)):toBeFalsy()
	end)

	it("supports Optional fields", function()
		local schema = V.Table({
			Fields = {
				Name = V.String(),
				Age = V.Optional(V.Number()),
			},
		})
		Expect(V.Validate({ Name = "a" }, schema)):toBeTruthy()
		Expect(V.Validate({ Name = "a", Age = 5 }, schema)):toBeTruthy()
		Expect(V.Validate({ Name = "a", Age = "x" }, schema)):toBeFalsy()
	end)
end)

describe("Validator payload checks", function()
	local limits = { MaxBytes = 100, MaxDepth = 2 }

	it("accepts supported native payloads", function()
		Expect(V.CheckPayload({ Damage = 5, Name = "x" }, limits)):toBeTruthy()
		Expect(V.CheckPayload(Vector3.new(1, 2, 3), { MaxBytes = 1000, MaxDepth = 2 })):toBeTruthy()
		local model = Instance.new("Model")
		Expect(V.CheckPayload({ Target = model }, { MaxBytes = 1000, MaxDepth = 2 })):toBeTruthy()
	end)

	it("rejects unsupported value types", function()
		local ok, err = V.CheckPayload({ callback = function() end }, limits)
		Expect(ok):toBeFalsy()
		Expect(err):toInclude("unsupported")
	end)

	it("rejects oversized payloads", function()
		Expect(V.CheckPayload(string.rep("a", 200), limits)):toBeFalsy()
	end)

	it("rejects overly deep structures", function()
		local deep = { a = { b = { c = { d = 1 } } } }
		Expect(V.CheckPayload(deep, { MaxBytes = 1000, MaxDepth = 2 })):toBeFalsy()
	end)

	it("rejects cyclic tables", function()
		local cyclic = {}
		cyclic.Self = cyclic
		local ok, err = V.CheckPayload(cyclic, { MaxBytes = 1000, MaxDepth = 8 })
		Expect(ok):toBeFalsy()
		Expect(err):toInclude("cyclic")
	end)

	it("rejects non-finite numbers and exotic keys", function()
		Expect(V.CheckPayload({ Value = 0 / 0 }, limits)):toBeFalsy()
		Expect(V.CheckPayload({ [true] = 1 }, limits)):toBeFalsy()
	end)
end)
