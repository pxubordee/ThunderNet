--!nonstrict
local ThunderNetFolder = game:GetService("ReplicatedStorage"):WaitForChild("ThunderNet")
local TestHarness = require(script.Parent.Parent.Support.TestHarness)
local Expect = require(script.Parent.Parent.Support.Expect)
local Middleware = require(ThunderNetFolder.Features.Middleware)

local describe, it = TestHarness.describe, TestHarness.it

local function newContext(overrides)
	local context = {
		Data = { Value = 1 },
		Channel = "Test",
		Kind = "Event",
		Side = "Server",
	}
	if overrides then
		for key, value in pairs(overrides) do
			context[key] = value
		end
	end
	return context
end

describe("Middleware", function()
	it("runs middleware in registration order and allows payload mutation", function()
		local pipeline = Middleware.new()
		local order = {}
		pipeline:Use(function(context, next)
			table.insert(order, "first")
			context.Data.Value += 10
			return next(context)
		end)
		pipeline:Use(function(context, next)
			table.insert(order, "second")
			context.Data.Value *= 2
			return next(context)
		end)

		local ok, finalContext, err = pipeline:Run(newContext())
		Expect(ok):toBeTruthy()
		Expect(err):toBeNil()
		Expect(order):toEqual({ "first", "second" })
		Expect(finalContext.Data.Value):toBe(22)
	end)

	it("supports context replacement through next()", function()
		local pipeline = Middleware.new()
		pipeline:Use(function(context, next)
			local replacement = newContext({ Data = { Value = 99 } })
			return next(replacement)
		end)
		local ok, finalContext = pipeline:Run(newContext())
		Expect(ok):toBeTruthy()
		Expect(finalContext.Data.Value):toBe(99)
	end)

	it("stops the chain when middleware returns false", function()
		local pipeline = Middleware.new()
		local downstreamRan = false
		pipeline:Use(function(context, next)
			return false, "NOPE"
		end)
		pipeline:Use(function(context, next)
			downstreamRan = true
			return next(context)
		end)
		local ok, _, err = pipeline:Run(newContext())
		Expect(ok):toBeFalsy()
		Expect(downstreamRan):toBeFalsy()
		Expect(err.Code):toBe("REJECTED")
		Expect(err.Message):toBe("NOPE")
	end)

	it("treats middleware that never calls next as incomplete", function()
		local pipeline = Middleware.new()
		pipeline:Use(function(context, next)
			return true
		end)
		local ok, _, err = pipeline:Run(newContext())
		Expect(ok):toBeFalsy()
		Expect(err.Code):toBe("MIDDLEWARE_INCOMPLETE")
	end)

	it("errors when next is called twice", function()
		local pipeline = Middleware.new()
		pipeline:Use(function(context, next)
			next(context)
			next(context)
		end)
		Expect(function()
			pipeline:Run(newContext())
		end):toThrow()
	end)

	it("propagates middleware errors", function()
		local pipeline = Middleware.new()
		pipeline:Use(function(context, next)
			error("middleware exploded", 0)
		end)
		Expect(function()
			pipeline:Run(newContext())
		end):toThrow()
	end)

	it("supports removal by token and reports counts", function()
		local pipeline = Middleware.new()
		local firstToken = pipeline:Use(function(context, next)
			return next(context)
		end)
		local secondToken = pipeline:Use(function(context, next)
			return next(context)
		end)
		Expect(pipeline:GetCount()):toBe(2)
		Expect(pipeline:Remove(firstToken)):toBeTruthy()
		Expect(pipeline:Remove(firstToken)):toBeFalsy()
		Expect(pipeline:GetCount()):toBe(1)
		local ok = pipeline:Run(newContext())
		Expect(ok):toBeTruthy()
		pipeline:Remove(secondToken)
		Expect(pipeline:GetCount()):toBe(0)
	end)

	it("skips middleware removed by an earlier middleware during the run", function()
		local pipeline = Middleware.new()
		local secondToken
		local secondRan = false
		pipeline:Use(function(context, next)
			pipeline:Remove(secondToken)
			return next(context)
		end)
		secondToken = pipeline:Use(function(context, next)
			secondRan = true
			return next(context)
		end)
		pipeline:Run(newContext())
		Expect(secondRan):toBeFalsy()
	end)

	it("rejects use after destruction and clears on destroy", function()
		local pipeline = Middleware.new()
		pipeline:Use(function(context, next)
			return next(context)
		end)
		pipeline:Destroy()
		Expect(pipeline:GetCount()):toBe(0)
		Expect(function()
			pipeline:Use(function(_, next)
				return next(_)
			end)
		end):toThrow()
	end)
end)
