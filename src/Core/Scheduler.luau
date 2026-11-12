--!strict
-- Frame-driven timer queue backed by a binary min-heap.
-- The owning network feeds Step() from RunService.Heartbeat.

local Scheduler = {}
Scheduler.__index = Scheduler

export type Timer = {
	At: number,
	Sequence: number,
	Callback: () -> (),
	Cancelled: boolean,
	Completed: boolean,
	ScheduledStep: number,
}

type State = {
	_heap: { Timer },
	_pending: number,
	_sequence: number,
	_step: number,
	_now: number,
	_destroyed: boolean,
}

export type Scheduler = State & {
	After: (self: Scheduler, seconds: number, callback: () -> ()) -> Timer,
	Cancel: (self: Scheduler, timer: Timer) -> boolean,
	GetPendingCount: (self: Scheduler) -> number,
	Step: (self: Scheduler, now: number) -> number,
	Destroy: (self: Scheduler) -> (),
}

local function before(first: Timer, second: Timer): boolean
	if first.At == second.At then
		return first.Sequence < second.Sequence
	end
	return first.At < second.At
end

local function swap(heap: { Timer }, first: number, second: number)
	heap[first], heap[second] = heap[second], heap[first]
end

local function siftUp(heap: { Timer }, index: number)
	while index > 1 do
		local parent = index // 2
		if before(heap[index], heap[parent]) then
			swap(heap, index, parent)
			index = parent
		else
			break
		end
	end
end

local function siftDown(heap: { Timer }, index: number)
	local size = #heap
	while true do
		local left = index * 2
		local right = left + 1
		local smallest = index
		if left <= size and before(heap[left], heap[smallest]) then
			smallest = left
		end
		if right <= size and before(heap[right], heap[smallest]) then
			smallest = right
		end
		if smallest == index then
			break
		end
		swap(heap, index, smallest)
		index = smallest
	end
end

local function push(self: Scheduler, timer: Timer)
	local heap = self._heap
	table.insert(heap, timer)
	siftUp(heap, #heap)
end

local function pop(self: Scheduler): Timer?
	local heap = self._heap
	local size = #heap
	if size == 0 then
		return nil
	end
	local root = heap[1]
	heap[1] = heap[size]
	heap[size] = nil
	if size > 1 then
		siftDown(heap, 1)
	end
	return root
end

function Scheduler.new(startNow: number?): Scheduler
	local self: Scheduler = setmetatable({
		_heap = {} :: { Timer },
		_pending = 0,
		_sequence = 0,
		_step = 0,
		_now = startNow or 0,
		_destroyed = false,
	}, Scheduler) :: any
	return self
end

local function after(self: Scheduler, seconds: number, callback: () -> ()): Timer
	if self._destroyed then
		error("Scheduler is destroyed", 3)
	end
	if type(callback) ~= "function" then
		error("Scheduler callback must be a function", 3)
	end
	self._sequence += 1
	local timer: Timer = {
		At = self._now + math.max(seconds, 0),
		Sequence = self._sequence,
		Callback = callback,
		Cancelled = false,
		Completed = false,
		ScheduledStep = self._step,
	}
	self._pending += 1
	push(self, timer)
	return timer
end
Scheduler.After = after

local function cancel(self: Scheduler, timer: Timer): boolean
	if timer.Cancelled or timer.Completed then
		return false
	end
	timer.Cancelled = true
	self._pending -= 1
	return true
end
Scheduler.Cancel = cancel

local function getPendingCount(self: Scheduler): number
	return self._pending
end
Scheduler.GetPendingCount = getPendingCount

local function step(self: Scheduler, now: number): number
	if self._destroyed then
		return 0
	end
	self._now = now
	self._step += 1
	local currentStep = self._step

	local ready: { Timer } = {}
	while true do
		local nextTimer = self._heap[1]
		if nextTimer == nil or nextTimer.At > now then
			break
		end
		local timer = pop(self) :: Timer
		if timer.Cancelled then
			continue
		end
		if timer.ScheduledStep >= currentStep then
			-- Timers created during this step run on the following step.
			push(self, timer)
			break
		end
		timer.Completed = true
		self._pending -= 1
		table.insert(ready, timer)
	end

	for index = 1, #ready do
		local ok, err = pcall(ready[index].Callback)
		if not ok then
			warn("Scheduler timer error: " .. tostring(err))
		end
	end

	return #ready
end
Scheduler.Step = step

local function destroy(self: Scheduler)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._heap = {}
	self._pending = 0
end
Scheduler.Destroy = destroy

return Scheduler
