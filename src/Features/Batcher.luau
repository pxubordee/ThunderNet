--!strict
-- Per-destination, per-lane, prioritized batching.
--
-- Guarantees:
--  - Messages are never mixed across destinations or between the reliable and
--    unreliable lanes.
--  - FIFO ordering is preserved inside a (destination, lane, priority) queue.
--  - Every non-empty priority gets service on each flush; under a tiny batch
--    budget, lower priorities are favored based on how long they have waited,
--    so no priority starves indefinitely.
--
-- The sender callback receives ready-to-send envelopes and is responsible for
-- packing them into a wire batch.

local Batcher = {}
Batcher.__index = Batcher

export type Config = {
	MaxBatchSize: number?,
	MaxBatchBytes: number?,
	FlushInterval: number?,
	Adaptive: boolean?,
	MaxLatency: number?,
	AdaptiveDepthThreshold: number?,
	-- UnreliableRemoteEvent calls are size-capped by Roblox (about 900 bytes);
	-- keep unreliable batches tiny by default and let users opt in explicitly.
	UnreliableBatchSize: number?,
	UnreliableMaxBytes: number?,
}

export type Sender = (destination: any, reliable: boolean, messages: { any }) -> ()

type Entry = {
	Message: any,
	Bytes: number,
}

type PriorityQueue = {
	Items: { Entry },
	Head: number,
	Tail: number,
}

type Lane = {
	Queues: { PriorityQueue },
	Counts: { number },
	Bytes: { number },
	TotalCount: number,
	TotalBytes: number,
	FirstQueuedAt: number?,
	Starvation: { number },
}

type DestinationState = {
	Reliable: Lane,
	Unreliable: Lane,
}

type ResolvedConfig = {
	MaxBatchSize: number,
	MaxBatchBytes: number,
	FlushInterval: number,
	Adaptive: boolean,
	MaxLatency: number,
	AdaptiveDepthThreshold: number,
	UnreliableBatchSize: number,
	UnreliableMaxBytes: number,
}

type State = {
	_destinations: { [any]: DestinationState },
	_sender: Sender,
	_config: ResolvedConfig,
	_queuedTotal: number,
	_destroyed: boolean,
}

export type Batcher = State & {
	Push: (
		self: Batcher,
		destination: any,
		message: any,
		priority: number,
		reliable: boolean,
		bytes: number?,
		now: number
	) -> (),
	GetQueueDepth: (self: Batcher) -> number,
	GetDestinationCount: (self: Batcher) -> number,
	Flush: (self: Batcher, destination: any?) -> (),
	Step: (self: Batcher, now: number) -> (),
	RemoveDestination: (self: Batcher, destination: any) -> (),
	Destroy: (self: Batcher) -> (),
}

local PRIORITY_COUNT = 5
local MAX_BATCHES_PER_STEP = 64

local function newQueue(): PriorityQueue
	return { Items = {}, Head = 1, Tail = 0 }
end

local function queueCount(queue: PriorityQueue): number
	if queue.Tail < queue.Head then
		return 0
	end
	return queue.Tail - queue.Head + 1
end

local function queuePush(queue: PriorityQueue, entry: Entry)
	queue.Tail += 1
	queue.Items[queue.Tail] = entry
end

local function queuePop(queue: PriorityQueue): Entry?
	if queue.Head > queue.Tail then
		return nil
	end
	local entry = queue.Items[queue.Head]
	queue.Items[queue.Head] = nil
	queue.Head += 1
	if queue.Head > queue.Tail then
		queue.Head = 1
		queue.Tail = 0
		queue.Items = {}
	end
	return entry
end

local function newLane(): Lane
	local queues: { PriorityQueue } = (table.create(PRIORITY_COUNT) :: any)
	local counts: { number } = (table.create(PRIORITY_COUNT) :: any)
	local bytes: { number } = (table.create(PRIORITY_COUNT) :: any)
	local starvation: { number } = (table.create(PRIORITY_COUNT) :: any)
	for index = 1, PRIORITY_COUNT do
		queues[index] = newQueue()
		counts[index] = 0
		bytes[index] = 0
		starvation[index] = 0
	end
	return {
		Queues = queues,
		Counts = counts,
		Bytes = bytes,
		TotalCount = 0,
		TotalBytes = 0,
		FirstQueuedAt = nil,
		Starvation = starvation,
	}
end

local function resolveConfig(config: Config?): ResolvedConfig
	local resolved: ResolvedConfig = {
		MaxBatchSize = (config and config.MaxBatchSize) or 64,
		MaxBatchBytes = (config and config.MaxBatchBytes) or 16384,
		FlushInterval = (config and config.FlushInterval) or 0,
		Adaptive = config ~= nil and config.Adaptive == true,
		MaxLatency = (config and config.MaxLatency) or 0.05,
		AdaptiveDepthThreshold = (config and config.AdaptiveDepthThreshold) or 16,
		UnreliableBatchSize = (config and config.UnreliableBatchSize) or 1,
		UnreliableMaxBytes = (config and config.UnreliableMaxBytes) or 900,
	}
	if resolved.MaxBatchSize < 1 or resolved.MaxBatchSize % 1 ~= 0 then
		error("Batcher MaxBatchSize must be a positive integer", 3)
	end
	if resolved.MaxBatchBytes < 1 then
		error("Batcher MaxBatchBytes must be positive", 3)
	end
	if resolved.FlushInterval < 0 then
		error("Batcher FlushInterval must be non-negative", 3)
	end
	if resolved.MaxLatency < 0 then
		error("Batcher MaxLatency must be non-negative", 3)
	end
	if resolved.AdaptiveDepthThreshold < 1 then
		error("Batcher AdaptiveDepthThreshold must be at least 1", 3)
	end
	if resolved.UnreliableBatchSize < 1 or resolved.UnreliableBatchSize % 1 ~= 0 then
		error("Batcher UnreliableBatchSize must be a positive integer", 3)
	end
	if resolved.UnreliableMaxBytes < 1 then
		error("Batcher UnreliableMaxBytes must be positive", 3)
	end
	return resolved
end

function Batcher.new(config: Config?, sender: Sender): Batcher
	if type(sender) ~= "function" then
		error("Batcher requires a sender callback", 2)
	end
	local self: Batcher = setmetatable({
		_destinations = {} :: { [any]: DestinationState },
		_sender = sender,
		_config = resolveConfig(config),
		_queuedTotal = 0,
		_destroyed = false,
	}, Batcher) :: any
	return self
end

local function push(
	self: Batcher,
	destination: any,
	message: any,
	priority: number,
	reliable: boolean,
	bytes: number?,
	now: number
)
	if self._destroyed then
		error("Batcher is destroyed", 3)
	end
	if destination == nil then
		error("Batcher requires a destination", 3)
	end
	if type(message) ~= "table" then
		error("Batcher message must be a table envelope", 3)
	end
	if type(priority) ~= "number" or priority % 1 ~= 0 or priority < 1 or priority > PRIORITY_COUNT then
		error("Batcher priority must be an integer 1..5", 3)
	end
	if type(reliable) ~= "boolean" then
		error("Batcher reliable flag must be a boolean", 3)
	end
	local byteSize = bytes or 0
	if byteSize < 0 then
		error("Batcher byte size cannot be negative", 3)
	end

	local state = self._destinations[destination]
	if not state then
		state = {
			Reliable = newLane(),
			Unreliable = newLane(),
		}
		self._destinations[destination] = state
	end
	local lane = if reliable then state.Reliable else state.Unreliable

	if lane.TotalCount == 0 then
		lane.FirstQueuedAt = now
	end
	lane.TotalCount += 1
	lane.TotalBytes += byteSize
	lane.Counts[priority] += 1
	lane.Bytes[priority] += byteSize
	queuePush(lane.Queues[priority], {
		Message = message,
		Bytes = byteSize,
	})
	self._queuedTotal += 1
end
Batcher.Push = push

local function getQueueDepth(self: Batcher): number
	return self._queuedTotal
end
Batcher.GetQueueDepth = getQueueDepth

local function getDestinationCount(self: Batcher): number
	local count = 0
	for _ in pairs(self._destinations) do
		count += 1
	end
	return count
end
Batcher.GetDestinationCount = getDestinationCount

local function laneLimits(config: ResolvedConfig, reliable: boolean): (number, number)
	if reliable then
		return config.MaxBatchSize, config.MaxBatchBytes
	end
	return math.min(config.MaxBatchSize, config.UnreliableBatchSize),
		math.min(config.MaxBatchBytes, config.UnreliableMaxBytes)
end

local function flushLane(self: Batcher, destination: any, reliable: boolean, lane: Lane)
	local config = self._config
	local maxBatchSize, maxBatchBytes = laneLimits(config, reliable)
	local batchesSent = 0

	while lane.TotalCount > 0 and batchesSent < MAX_BATCHES_PER_STEP do
		local order = {}
		for priority = 1, PRIORITY_COUNT do
			if queueCount(lane.Queues[priority]) > 0 then
				table.insert(order, priority)
			end
		end
		if #order == 0 then
			break
		end
		table.sort(order, function(first, second)
			local firstStarvation = lane.Starvation[first]
			local secondStarvation = lane.Starvation[second]
			if firstStarvation ~= secondStarvation then
				return firstStarvation > secondStarvation
			end
			return first < second
		end)

		local batch = {}
		local batchBytes = 0
		local served: { [number]: boolean } = {}

		while lane.TotalCount > 0 and #batch < maxBatchSize do
			local tookAny = false
			for _, priority in ipairs(order) do
				if #batch >= maxBatchSize then
					break
				end
				local queue = lane.Queues[priority]
				if queueCount(queue) > 0 then
					local head = queue.Items[queue.Head] :: Entry
					local fitsBytes = batchBytes + head.Bytes <= maxBatchBytes
					if #batch == 0 or fitsBytes then
						local entry = queuePop(queue) :: Entry
						lane.TotalCount -= 1
						lane.TotalBytes -= entry.Bytes
						lane.Counts[priority] -= 1
						lane.Bytes[priority] -= entry.Bytes
						self._queuedTotal -= 1
						table.insert(batch, entry.Message)
						batchBytes += entry.Bytes
						served[priority] = true
						tookAny = true
					end
				end
			end
			if not tookAny then
				break
			end
		end

		for priority = 1, PRIORITY_COUNT do
			if served[priority] then
				lane.Starvation[priority] = 0
			elseif queueCount(lane.Queues[priority]) > 0 then
				lane.Starvation[priority] += 1
			end
		end

		if lane.TotalCount == 0 then
			lane.FirstQueuedAt = nil
		end

		if #batch > 0 then
			batchesSent += 1
			self._sender(destination, reliable, batch)
		else
			break
		end
	end
end

local function flushDestination(self: Batcher, destination: any)
	local state = self._destinations[destination]
	if not state then
		return
	end
	if state.Reliable.TotalCount > 0 then
		flushLane(self, destination, true, state.Reliable)
	end
	if state.Unreliable.TotalCount > 0 then
		flushLane(self, destination, false, state.Unreliable)
	end
end

local function flush(self: Batcher, destination: any?)
	if self._destroyed then
		return
	end
	if destination ~= nil then
		flushDestination(self, destination)
		return
	end
	for key in pairs(self._destinations) do
		flushDestination(self, key)
	end
end
Batcher.Flush = flush

local function laneIsDue(lane: Lane, config: ResolvedConfig, now: number, reliable: boolean): boolean
	if lane.TotalCount == 0 then
		return false
	end
	local maxBatchSize, maxBatchBytes = laneLimits(config, reliable)
	if lane.TotalCount >= maxBatchSize or lane.TotalBytes >= maxBatchBytes then
		return true
	end
	local interval = config.FlushInterval
	if config.Adaptive and lane.TotalCount >= config.AdaptiveDepthThreshold then
		interval = math.max(interval, config.MaxLatency)
	end
	local firstQueuedAt = lane.FirstQueuedAt or now
	return now - firstQueuedAt >= interval
end

local function step(self: Batcher, now: number)
	if self._destroyed then
		return
	end
	local config = self._config
	for destination, state in pairs(self._destinations) do
		if laneIsDue(state.Reliable, config, now, true) then
			flushLane(self, destination, true, state.Reliable)
		end
		if laneIsDue(state.Unreliable, config, now, false) then
			flushLane(self, destination, false, state.Unreliable)
		end
	end
end
Batcher.Step = step

local function removeDestination(self: Batcher, destination: any)
	local state = self._destinations[destination]
	if not state then
		return
	end
	self._queuedTotal -= state.Reliable.TotalCount + state.Unreliable.TotalCount
	self._destinations[destination] = nil
end
Batcher.RemoveDestination = removeDestination

local function destroy(self: Batcher)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._destinations = {}
	self._queuedTotal = 0
end
Batcher.Destroy = destroy

return Batcher
