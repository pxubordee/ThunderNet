--!strict
-- Retry policy: exponential backoff with bounded jitter and a hard attempt
-- budget. Pure: no timers or requests live here.

local RetryManager = {}
RetryManager.__index = RetryManager

export type Config = {
	MaxAttempts: number?,
	BaseDelay: number?,
	MaxDelay: number?,
	Jitter: number?,
	Random: (() -> number)?,
}

type State = {
	_maxAttempts: number,
	_baseDelay: number,
	_maxDelay: number,
	_jitter: number,
	_random: () -> number,
}

export type RetryManager = State & {
	GetMaxAttempts: (self: RetryManager) -> number,
	ShouldRetry: (self: RetryManager, attemptsSoFar: number) -> boolean,
	NextDelay: (self: RetryManager, retryIndex: number) -> number,
}

function RetryManager.new(config: Config?): RetryManager
	local maxAttempts = (config and config.MaxAttempts) or 3
	local baseDelay = (config and config.BaseDelay) or 0.5
	local maxDelay = (config and config.MaxDelay) or 8
	local jitter = (config and config.Jitter) or 0.2
	local random = (config and config.Random) or math.random

	if type(maxAttempts) ~= "number" or maxAttempts < 1 or maxAttempts % 1 ~= 0 then
		error("RetryManager MaxAttempts must be a positive integer", 3)
	end
	if type(baseDelay) ~= "number" or baseDelay < 0 then
		error("RetryManager BaseDelay must be non-negative", 3)
	end
	if type(maxDelay) ~= "number" or maxDelay < baseDelay then
		error("RetryManager MaxDelay must be at least BaseDelay", 3)
	end
	if type(jitter) ~= "number" or jitter < 0 or jitter > 1 then
		error("RetryManager Jitter must be between 0 and 1", 3)
	end
	if type(random) ~= "function" then
		error("RetryManager Random must be a function", 3)
	end

	local self: RetryManager = setmetatable({
		_maxAttempts = maxAttempts,
		_baseDelay = baseDelay,
		_maxDelay = maxDelay,
		_jitter = jitter,
		_random = random,
	}, RetryManager) :: any
	return self
end

local function getMaxAttempts(self: RetryManager): number
	return self._maxAttempts
end
RetryManager.GetMaxAttempts = getMaxAttempts

-- attemptsSoFar includes the first attempt.
local function shouldRetry(self: RetryManager, attemptsSoFar: number): boolean
	return attemptsSoFar < self._maxAttempts
end
RetryManager.ShouldRetry = shouldRetry

-- retryIndex 1 = delay before the first retry.
local function nextDelay(self: RetryManager, retryIndex: number): number
	local index = math.max(1, math.floor(retryIndex))
	local delay = math.min(self._maxDelay, self._baseDelay * 2 ^ (index - 1))
	if self._jitter > 0 then
		local sample: number = self._random()
		delay = delay * (1 + self._jitter * (2 * sample - 1))
	end
	return math.max(0, delay)
end
RetryManager.NextDelay = nextDelay

return RetryManager
