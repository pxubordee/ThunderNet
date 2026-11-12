--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Compression = require(ThunderNetFolder.Features.Compression)

local describe, it = TestHarness.describe, TestHarness.it
local RLE = Compression.RLE

describe("Compression codec", function()
	it("round-trips representative binary strings", function()
		local samples = {
			"",
			"A",
			"ABC",
			string.rep("A", 1000),
			string.rep("AB", 500),
			string.char(0, 0, 0, 0, 1, 2, 3, 255, 255, 255, 255),
		}
		local mixed = {}
		for index = 0, 255 do
			table.insert(mixed, string.char(index))
		end
		table.insert(samples, string.rep(table.concat(mixed), 4))

		for _, sample in ipairs(samples) do
			local encoded = RLE.Encode(sample)
			local decoded, err = RLE.Decode(encoded, 1_000_000)
			Expect(err):toBeNil()
			Expect(decoded):toBe(sample)
		end
	end)

	it("compresses repetitive data and leaves incompressible data larger", function()
		local repetitive = string.rep("A", 900)
		local encoded = RLE.Encode(repetitive)
		Expect(#encoded < #repetitive):toBeTruthy()

		local incompressible = string.char(65, 0, 66, 1, 67, 2, 68, 3, 69, 4)
		local encodedTiny = RLE.Encode(incompressible)
		Expect(#encodedTiny >= #incompressible):toBeTruthy()
	end)

	it("rejects truncated and invalid streams", function()
		Expect(select(2, RLE.Decode("\0\5ab", 100))):toBeTruthy()
		Expect(select(2, RLE.Decode("\2", 100))):toBeTruthy()
		Expect(select(2, RLE.Decode("\1", 100))):toBeTruthy()
		Expect(select(2, RLE.Decode("\1\2", 100))):toBeTruthy()
		Expect(select(2, RLE.Decode("\0\0", 100))):toBeTruthy()
	end)

	it("enforces the decompression output limit", function()
		local encoded = RLE.Encode(string.rep("A", 5000))
		local decoded, err = RLE.Decode(encoded, 100)
		Expect(decoded):toBeNil()
		Expect(err):toBeTruthy()
	end)
end)

describe("Compression pipeline", function()
	it("passes data through when disabled", function()
		local compression = Compression.new({ Enabled = false, Threshold = 0 })
		local encoded, compressed = compression:Compress(string.rep("A", 1000))
		Expect(compressed):toBeFalsy()
		Expect(#encoded):toBe(1000)
	end)

	it("compresses only when savings justify the CPU cost", function()
		local compression = Compression.new({ Enabled = true, Threshold = 10, MinSavingsRatio = 0.8 })
		local encoded, compressed = compression:Compress(string.rep("A", 1000))
		Expect(compressed):toBeTruthy()
		Expect(#encoded < 100):toBeTruthy()

		local tiny = compression:Compress("hi")
		Expect(tiny):toBe("hi")

		local small = Compression.new({ Enabled = true, Threshold = 100 })
		local passthrough, wasCompressed = small:Compress(string.rep("A", 50))
		Expect(wasCompressed):toBeFalsy()
		Expect(#passthrough):toBe(50)
	end)

	it("decompresses through the configured codec", function()
		local compression = Compression.new({ Enabled = true, Threshold = 0, MinSavingsRatio = 1 })
		local encoded, compressed = compression:Compress(string.rep("Z", 500))
		Expect(compressed):toBeTruthy()
		local decoded, err = compression:Decompress(encoded)
		Expect(err):toBeNil()
		Expect(decoded):toBe(string.rep("Z", 500))
	end)

	it("accepts custom codecs", function()
		local decodeCalled = false
		local codec = {
			Name = "store",
			Encode = function(value)
				return value
			end,
			Decode = function(value)
				decodeCalled = true
				return value
			end,
		}
		local compression = Compression.new({
			Enabled = true,
			Threshold = 0,
			MinSavingsRatio = 1,
			Codec = codec,
		})
		local encoded, compressed = compression:Compress("payload")
		Expect(compressed):toBeTruthy()
		local decoded = compression:Decompress(encoded)
		Expect(decodeCalled):toBeTruthy()
		Expect(decoded):toBe("payload")
	end)

	it("rejects invalid codec definitions", function()
		Expect(function()
			Compression.new({ Codec = { Encode = function(v) return v end } })
		end):toThrow()
	end)

	it("caps decompressed output", function()
		local compression = Compression.new({ Enabled = true, Threshold = 0, MaxDecompressedBytes = 50 })
		local encoded = compression:Compress(string.rep("A", 1000))
		local decoded, err = compression:Decompress(encoded)
		Expect(decoded):toBeNil()
		Expect(err):toBeTruthy()
	end)
end)
