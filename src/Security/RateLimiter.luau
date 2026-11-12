--!strict
-- Token-bucket rate limiting with per-player, per-key buckets.
-- Time is passed in by the caller so the network owns the clock.

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type Config = {
	DefaultRate: number?,
	DefaultBurst: number?,
}

type Bucket = {
	Tokens: number,
	Rate: number,
	Burst: number,
	LastRefill: number,
}

type PlayerBuckets = { [string]: Bucket }

type State = {
	_players: { [any]: PlayerBuckets },
	_defaultRate: number,
	_defaultBurst: number,
}

export type RateLimiter = State & {
	Allow: (
		self: RateLimiter,
		player: any,
		key: string?,
		rate: number?,
		burst: number?,
		now: number
	) -> (boolean, number?),
	RemovePlayer: (self: RateLimiter, player: any) -> (),
	GetEntryCount: (self: RateLimiter) -> number,
	Destroy: (self: RateLimiter) -> (),
}

local DEFAULT_RATE = 120
local DEFAULT_BURST = 240

function RateLimiter.new(config: Config?): RateLimiter
	local defaultRate = (config and config.DefaultRate) or DEFAULT_RATE
	local defaultBurst = (config and config.DefaultBurst) or DEFAULT_BURST
	if defaultRate <= 0 then
		error("RateLimiter DefaultRate must be positive", 3)
	end
	if defaultBurst < 1 then
		error("RateLimiter DefaultBurst must be at least 1", 3)
	end
	local self: RateLimiter = setmetatable({
		_players = {} :: { [any]: PlayerBuckets },
		_defaultRate = defaultRate,
		_defaultBurst = defaultBurst,
	}, RateLimiter) :: any
	return self
end

-- Returns (allowed, retryAfterSeconds). retryAfter is math.huge when the
-- configured rate cannot ever allow another message.
local function allow(
	self: RateLimiter,
	player: any,
	key: string?,
	rate: number?,
	burst: number?,
	now: number
): (boolean, number?)
	local bucketKey = key or ""
	local effectiveRate = rate or self._defaultRate
	local effectiveBurst = burst or self._defaultBurst
	if effectiveRate <= 0 or effectiveBurst < 1 then
		return false, math.huge
	end

	local playerBuckets = self._players[player]
	if not playerBuckets then
		playerBuckets = {}
		self._players[player] = playerBuckets
	end

	local bucket = playerBuckets[bucketKey]
	if not bucket then
		bucket = {
			Tokens = effectiveBurst,
			Rate = effectiveRate,
			Burst = effectiveBurst,
			LastRefill = now,
		}
		playerBuckets[bucketKey] = bucket
	else
		bucket.Rate = effectiveRate
		bucket.Burst = effectiveBurst
		if bucket.Tokens > effectiveBurst then
			bucket.Tokens = effectiveBurst
		end
	end

	local elapsed = now - bucket.LastRefill
	if elapsed > 0 then
		bucket.Tokens = math.min(bucket.Burst, bucket.Tokens + elapsed * bucket.Rate)
		bucket.LastRefill = now
	end

	if bucket.Tokens >= 1 then
		bucket.Tokens -= 1
		return true, nil
	end

	return false, (1 - bucket.Tokens) / bucket.Rate
end
RateLimiter.Allow = allow

local function removePlayer(self: RateLimiter, player: any)
	self._players[player] = nil
end
RateLimiter.RemovePlayer = removePlayer

local function getEntryCount(self: RateLimiter): number
	local count = 0
	for _, buckets in pairs(self._players) do
		for _ in pairs(buckets) do
			count += 1
		end
	end
	return count
end
RateLimiter.GetEntryCount = getEntryCount

local function destroy(self: RateLimiter)
	self._players = {}
end
RateLimiter.Destroy = destroy

return RateLimiter
