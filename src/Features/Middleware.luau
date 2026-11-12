--!strict
-- Ordered middleware pipeline. Middleware must call next() exactly once to
-- continue; returning false rejects the message. Payload mutation is done via
-- the context table (or by replacing it in next()).

local Middleware = {}
Middleware.__index = Middleware

export type Context = {
	Data: any,
	Channel: string,
	Kind: string,
	Side: string,
	Player: any?,
	RequestId: string?,
	[any]: any,
}

export type RejectionError = {
	Code: string,
	Message: string,
	Details: any?,
}

export type Next = (context: Context?) -> (boolean, Context?, any)
export type MiddlewareFunction = (context: Context, next: Next) -> (any, any)

type Entry = {
	Id: number,
	Function: MiddlewareFunction,
	Removed: boolean,
}

type State = {
	_chain: { Entry },
	_nextId: number,
	_destroyed: boolean,
}

export type Middleware = State & {
	Use: (self: Middleware, middleware: MiddlewareFunction) -> number,
	Remove: (self: Middleware, token: number) -> boolean,
	GetCount: (self: Middleware) -> number,
	Run: (self: Middleware, context: Context) -> (boolean, Context?, any),
	Destroy: (self: Middleware) -> (),
}

function Middleware.new(): Middleware
	local self: Middleware = setmetatable({
		_chain = {} :: { Entry },
		_nextId = 0,
		_destroyed = false,
	}, Middleware) :: any
	return self
end

local function use(self: Middleware, middleware: MiddlewareFunction): number
	if self._destroyed then
		error("Middleware pipeline is destroyed", 3)
	end
	if type(middleware) ~= "function" then
		error("Middleware must be a function", 3)
	end
	self._nextId += 1
	table.insert(self._chain, {
		Id = self._nextId,
		Function = middleware,
		Removed = false,
	})
	return self._nextId
end
Middleware.Use = use

local function remove(self: Middleware, token: number): boolean
	if self._destroyed then
		return false
	end
	for _, entry in ipairs(self._chain) do
		if entry.Id == token and not entry.Removed then
			entry.Removed = true
			return true
		end
	end
	return false
end
Middleware.Remove = remove

local function getCount(self: Middleware): number
	local count = 0
	for _, entry in ipairs(self._chain) do
		if not entry.Removed then
			count += 1
		end
	end
	return count
end
Middleware.GetCount = getCount

local function normalizeRejection(reason: any): RejectionError
	if type(reason) == "table" and type(reason.Code) == "string" then
		return reason
	end
	if type(reason) == "string" then
		return { Code = "REJECTED", Message = reason }
	end
	return { Code = "REJECTED", Message = "Rejected by middleware" }
end

local function run(self: Middleware, context: Context): (boolean, Context?, any)
	if self._destroyed then
		error("Middleware pipeline is destroyed", 3)
	end
	local chain = self._chain
	local limit = #chain
	local index = 0

	local function runFrom(currentContext: Context): (boolean, Context?, any)
		local entry: Entry
		while true do
			index += 1
			if index > limit then
				return true, currentContext, nil
			end
			local candidate: Entry = chain[index]
			if not candidate.Removed then
				entry = candidate
				break
			end
		end

		local called = false
		local downstreamOk = false
		local downstreamContext = currentContext
		local downstreamError: any = nil

		local function nextFn(replacement: Context?): (boolean, Context?, any)
			if called then
				error("Middleware next() may only be called once", 3)
			end
			called = true
			if replacement ~= nil and type(replacement) ~= "table" then
				downstreamError = {
					Code = "REJECTED",
					Message = "next() received a non-table context",
				}
				return false, downstreamContext, downstreamError
			end
			local ok, resultContext, err = runFrom(replacement or currentContext)
			downstreamOk = ok
			downstreamContext = resultContext or currentContext
			downstreamError = err
			return ok, resultContext, err
		end

		local result, reason = entry.Function(currentContext, nextFn)
		if result == false then
			return false, downstreamContext, normalizeRejection(reason)
		end
		if not called then
			return false, currentContext, {
				Code = "MIDDLEWARE_INCOMPLETE",
				Message = "Middleware did not call next()",
			}
		end
		return downstreamOk, downstreamContext, downstreamError
	end

	return runFrom(context)
end
Middleware.Run = run

local function destroy(self: Middleware)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._chain = {}
end
Middleware.Destroy = destroy

return Middleware
