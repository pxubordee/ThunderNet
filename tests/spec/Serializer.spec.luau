--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Serializer = require(ThunderNetFolder.Features.Serializer)

local describe, it = TestHarness.describe, TestHarness.it

local function roundTrip(value)
	local encoded = Serializer.Encode(value)
	local decoded, err = Serializer.Decode(encoded)
	Expect(err):toBeNil()
	return decoded
end

describe("Serializer", function()
	it("round-trips primitives", function()
		Expect(roundTrip(nil)):toBeNil()
		Expect(roundTrip(true)):toBeTruthy()
		Expect(roundTrip(false)):toBeFalsy()
		Expect(roundTrip(0)):toBe(0)
		Expect(roundTrip(-12.5)):toBe(-12.5)
		Expect(roundTrip(1e300)):toBe(1e300)
		Expect(roundTrip("")):toBe("")
		Expect(roundTrip("hello world")):toBe("hello world")
		local binary = string.char(0, 1, 2, 255, 254, 0)
		Expect(roundTrip(binary)):toBe(binary)
	end)

	it("round-trips nested tables preserving keys and values", function()
		local value = {
			Name = "Thunder",
			Count = 3,
			Nested = {
				[1] = "a",
				[2] = "b",
				[10] = "gap-tolerant",
				Flag = true,
			},
			Ratio = 0.25,
		}
		local decoded = roundTrip(value)
		Expect(decoded.Name):toBe("Thunder")
		Expect(decoded.Count):toBe(3)
		Expect(decoded.Nested[1]):toBe("a")
		Expect(decoded.Nested[2]):toBe("b")
		Expect(decoded.Nested[10]):toBe("gap-tolerant")
		Expect(decoded.Nested.Flag):toBeTruthy()
		Expect(decoded.Ratio):toBe(0.25)
	end)

	it("round-trips supported Roblox datatypes", function()
		local vector = roundTrip(Vector3.new(1.5, -2.25, 3))
		Expect(vector.X):toBeNear(1.5)
		Expect(vector.Y):toBeNear(-2.25)
		Expect(vector.Z):toBeNear(3)

		local color = roundTrip(Color3.new(0.1, 0.2, 0.3))
		Expect(color.R):toBeNear(0.1, 1e-6)
		Expect(color.G):toBeNear(0.2, 1e-6)
		Expect(color.B):toBeNear(0.3, 1e-6)

		local udim = roundTrip(UDim.new(0.5, 10))
		Expect(udim.Scale):toBeNear(0.5)
		Expect(udim.Offset):toBe(10)

		local udim2 = roundTrip(UDim2.new(0.1, 2, 0.3, 4))
		Expect(udim2.X.Scale):toBeNear(0.1, 1e-6)
		Expect(udim2.X.Offset):toBe(2)
		Expect(udim2.Y.Scale):toBeNear(0.3, 1e-6)
		Expect(udim2.Y.Offset):toBe(4)

		local cframe = roundTrip(CFrame.new(1, 2, 3))
		Expect(cframe.X):toBeNear(1)
		Expect(cframe.Y):toBeNear(2)
		Expect(cframe.Z):toBeNear(3)
		Expect(cframe.R00):toBeNear(1)
		Expect(cframe.R11):toBeNear(1)
		Expect(cframe.R22):toBeNear(1)
	end)

	it("rejects unsupported values during encoding", function()
		Expect(function()
			Serializer.Encode(function() end)
		end):toThrow()
		Expect(function()
			Serializer.Encode({ Callback = function() end })
		end):toThrow()
		Expect(function()
			Serializer.Encode({ [true] = 1 })
		end):toThrow()
	end)

	it("rejects malformed binary input instead of throwing", function()
		local decoded, err = Serializer.Decode("\255\255\255")
		Expect(decoded):toBeNil()
		Expect(err):toBeTruthy()

		local truncated = Serializer.Decode(string.sub(Serializer.Encode("hello"), 1, 3))
		Expect(truncated):toBeNil()

		local trailing = Serializer.Decode(Serializer.Encode("ok") .. "extra")
		Expect(trailing):toBeNil()
	end)

	it("enforces depth limits while encoding and decoding", function()
		local deep = { a = { b = { c = { d = 1 } } } }
		Expect(function()
			Serializer.Encode(deep, { MaxDepth = 2 })
		end):toThrow()

		local encoded = Serializer.Encode(deep, { MaxDepth = 8 })
		local decoded, err = Serializer.Decode(encoded, { MaxDepth = 2 })
		Expect(decoded):toBeNil()
		Expect(err):toBeTruthy()
	end)

	it("enforces string, entry and byte limits", function()
		Expect(function()
			Serializer.Encode(string.rep("a", 100), { MaxStringLength = 10 })
		end):toThrow()

		Expect(function()
			Serializer.Encode({ 1, 2, 3, 4, 5 }, { MaxEntries = 3 })
		end):toThrow()

		Expect(function()
			Serializer.Encode(string.rep("a", 100), { MaxBytes = 20 })
		end):toThrow()

		local encoded = Serializer.Encode(string.rep("a", 10))
		local decoded, err = Serializer.Decode(encoded, { MaxBytes = 5 })
		Expect(decoded):toBeNil()
		Expect(err):toBeTruthy()
	end)

	it("measures payload sizes for batching", function()
		local small = Serializer.Measure({ A = 1, B = "xy" })
		Expect(small > 8):toBeTruthy()
		local large = Serializer.Measure(string.rep("x", 5000))
		Expect(large >= 5000):toBeTruthy()
		Expect(Serializer.Measure(true) >= 1):toBeTruthy()
	end)

	it("gates encoding behind the Enabled config", function()
		local disabled = Serializer.new({})
		Expect(disabled:IsEnabled()):toBeFalsy()
		local enabled = Serializer.new({ Enabled = true })
		Expect(enabled:IsEnabled()):toBeTruthy()
		local encoded = enabled:Encode({ Value = 1 })
		local decoded = enabled:Decode(encoded)
		Expect(decoded.Value):toBe(1)
	end)
end)
