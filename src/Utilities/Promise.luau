--!strict
-- Minimal promise implementation used for request/response plumbing.
-- Callbacks run synchronously when the promise settles; handlers are protected
-- so a thrown error rejects the derived promise instead of the source.

local Promise = {}
Promise.__index = Promise

export type Status = "Pending" | "Resolved" | "Rejected" | "Cancelled"

type ResolveHandler = (any) -> any
type RejectHandler = (any) -> any

type CallbackEntry = {
	OnResolved: ResolveHandler?,
	OnRejected: RejectHandler?,
	Next: any,
}

type State = {
	_status: Status,
	_value: any,
	_callbacks: { CallbackEntry },
	_cancelHooks: { () -> () },
}

export type Promise = State & {
	Resolve: (self: Promise, value: any) -> (),
	Reject: (self: Promise, reason: any) -> (),
	Cancel: (self: Promise) -> (),
	AndThen: (self: Promise, onResolved: ResolveHandler?) -> Promise,
	Catch: (self: Promise, onRejected: RejectHandler?) -> Promise,
	Finally: (self: Promise, callback: () -> ()) -> Promise,
	OnCancel: (self: Promise, handler: () -> ()) -> (),
	Await: (self: Promise, timeout: number?) -> any,
	GetStatus: (self: Promise) -> Status,
}

-- Typed structural view of a promise for generic APIs (RPC results).
export type PromiseOf<T = any> = {
	Resolve: (self: PromiseOf<T>, value: T) -> (),
	Reject: (self: PromiseOf<T>, reason: any) -> (),
	Cancel: (self: PromiseOf<T>) -> (),
	OnCancel: (self: PromiseOf<T>, handler: () -> ()) -> (),
	Await: (self: PromiseOf<T>, timeout: number?) -> T,
	GetStatus: (self: PromiseOf<T>) -> Status,
	AndThen: (self: PromiseOf<T>, onResolved: ((T) -> any)?) -> PromiseOf<T>,
	Catch: (self: PromiseOf<T>, onRejected: ((any) -> any)?) -> PromiseOf<T>,
	Finally: (self: PromiseOf<T>, callback: () -> ()) -> PromiseOf<T>,
}

export type CancellationError = {
	Code: string,
	Message: string,
}

function Promise.new(): Promise
	local self: Promise = setmetatable({
		_status = "Pending",
		_value = nil,
		_callbacks = {} :: { CallbackEntry },
		_cancelHooks = {} :: { () -> () },
	}, Promise) :: any
	return self
end

function Promise.resolve(value: any): Promise
	local promise = Promise.new()
	promise:Resolve(value)
	return promise
end

function Promise.reject(reason: any): Promise
	local promise = Promise.new()
	promise:Reject(reason)
	return promise
end

function Promise.all(items: { any }): Promise
	local combined = Promise.new()
	local count = #items
	if count == 0 then
		combined:Resolve({})
		return combined
	end

	local results: { [number]: any } = {}
	local remaining = count
	local settled = false

	for index = 1, count do
		local item = items[index]
		local promise: Promise
		if type(item) == "table" and type(item.AndThen) == "function" then
			promise = item :: Promise
		else
			promise = Promise.resolve(item)
		end
		promise
			:AndThen(function(value: any): any
				if settled then
					return nil
				end
				results[index] = value
				remaining -= 1
				if remaining == 0 then
					settled = true
					combined:Resolve(results)
				end
				return nil
			end)
			:Catch(function(err: any): any
				if settled then
					return nil
				end
				settled = true
				combined:Reject(err)
				return nil
			end)
	end

	return combined
end

local function forward(handler: (any) -> any, value: any, nextPromise: Promise)
	local ok, result = pcall(handler, value)
	if ok then
		nextPromise:Resolve(result)
	else
		nextPromise:Reject(result)
	end
end

local function settle(self: Promise, entry: CallbackEntry)
	local nextPromise = entry.Next :: Promise
	if self._status == "Resolved" then
		local handler = entry.OnResolved
		if handler then
			forward(handler, self._value, nextPromise)
		else
			nextPromise:Resolve(self._value)
		end
	else
		local handler = entry.OnRejected
		if handler then
			forward(handler, self._value, nextPromise)
		else
			nextPromise:Reject(self._value)
		end
	end
end
Promise._settle = settle

local function resolveImpl(self: Promise, value: any)
	if self._status ~= "Pending" then
		return
	end
	self._status = "Resolved"
	self._value = value
	local callbacks = self._callbacks
	self._callbacks = {}
	for index = 1, #callbacks do
		settle(self, callbacks[index])
	end
end
Promise.Resolve = resolveImpl

local function rejectImpl(self: Promise, reason: any)
	if self._status ~= "Pending" then
		return
	end
	self._status = "Rejected"
	self._value = reason
	local callbacks = self._callbacks
	self._callbacks = {}
	for index = 1, #callbacks do
		settle(self, callbacks[index])
	end
end
Promise.Reject = rejectImpl

local function cancelImpl(self: Promise)
	if self._status ~= "Pending" then
		return
	end
	local cancellationError: CancellationError = {
		Code = "CANCELLED",
		Message = "Promise was cancelled",
	}
	self._status = "Cancelled"
	self._value = cancellationError
	local hooks = self._cancelHooks
	self._cancelHooks = {}
	for index = 1, #hooks do
		pcall(hooks[index])
	end
	local callbacks = self._callbacks
	self._callbacks = {}
	for index = 1, #callbacks do
		settle(self, callbacks[index])
	end
end
Promise.Cancel = cancelImpl

local function andThen(self: Promise, onResolved: ResolveHandler?): Promise
	local nextPromise = Promise.new()
	local entry: CallbackEntry = {
		OnResolved = onResolved,
		OnRejected = nil,
		Next = nextPromise,
	}
	if self._status == "Pending" then
		table.insert(self._callbacks, entry)
	else
		settle(self, entry)
	end
	return nextPromise
end
Promise.AndThen = andThen

local function catch(self: Promise, onRejected: RejectHandler?): Promise
	local nextPromise = Promise.new()
	local entry: CallbackEntry = {
		OnResolved = nil,
		OnRejected = onRejected,
		Next = nextPromise,
	}
	if self._status == "Pending" then
		table.insert(self._callbacks, entry)
	else
		settle(self, entry)
	end
	return nextPromise
end
Promise.Catch = catch

local function finally(self: Promise, callback: () -> ()): Promise
	return self
		:AndThen(function(value: any): any
			callback()
			return value
		end)
		:Catch(function(reason: any): any
			callback()
			error(reason, 0)
			return nil
		end)
end
Promise.Finally = finally

local function onCancel(self: Promise, handler: () -> ())
	if self._status == "Cancelled" then
		handler()
		return
	end
	if self._status ~= "Pending" then
		return
	end
	table.insert(self._cancelHooks, handler)
end
Promise.OnCancel = onCancel

local function await(self: Promise, timeout: number?): any
	local deadline: number? = nil
	if timeout then
		deadline = os.clock() + timeout
	end
	while self._status == "Pending" do
		if deadline and os.clock() >= deadline then
			error({
				Code = "TIMEOUT",
				Message = "Await timed out after " .. tostring(timeout) .. "s",
			}, 0)
		end
		task.wait(0)
	end
	if self._status == "Resolved" then
		return self._value
	end
	error(self._value, 0)
end
Promise.Await = await

local function getStatus(self: Promise): Status
	return self._status
end
Promise.GetStatus = getStatus

return Promise
