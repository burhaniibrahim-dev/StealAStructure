-- Responsibility: Authoritative target and run records and their indexes. No gameplay rules, no Roblox instances.
-- Holds only live entities: a starter or scoring target leaves the registry the moment it is claimed, destroyed,
-- expired, or removed (its model may still play an exit animation; TargetService tracks that separately).
-- TargetIds and RunIds are server-issued, increasing, and never reused, so a stale id can never reach a newer entity.
--
-- Target records (Kind "Starter" or "Scoring"):
--   common   TargetId, Kind, TargetTypeId, ZoneId, Position, CreatedAt, Model
--   Starter  Settings (the zone's Targets entry, locked into the run on claim), ClaimableAt, ExpiresAt
--   Scoring  RunId, OwnerUserId, MaxHealth, Health, Removed, State ("AwaitingAck" | "Live"),
--            AckDeadline, AckAt?, DamageUnlockAt?, Deadline?
-- Run records:
--   RunId, OwnerUserId, Player, TargetTypeId, ZoneId, Settings, Origin, State ("Waiting" | "Active" | "Settled"),
--   Score, SpawnIndex, Radius, MaxHealth, BatchesLeft, NextAt?, TargetId?

local TargetRegistry = {}
TargetRegistry.__index = TargetRegistry

TargetRegistry.Kind = {
	Starter = "Starter",
	Scoring = "Scoring",
}

function TargetRegistry.new()
	return setmetatable({
		_nextTargetId = 0,
		_nextRunId = 0,
		_targets = {}, -- [TargetId] = record (starters and scoring targets)
		_starterCounts = {}, -- [ZoneId] = live starters
		_runs = {}, -- [RunId] = run
		_runByOwner = {}, -- [UserId] = run
	}, TargetRegistry)
end

local function create(self, fields, kind)
	self._nextTargetId += 1
	local record = table.clone(fields)
	record.TargetId = self._nextTargetId
	record.Kind = kind
	self._targets[record.TargetId] = record
	return record
end

function TargetRegistry:CreateStarter(fields)
	assert(fields.ZoneId ~= nil, "Every starter needs a ZoneId")
	local record = create(self, fields, TargetRegistry.Kind.Starter)
	self._starterCounts[record.ZoneId] = (self._starterCounts[record.ZoneId] or 0) + 1
	return record
end

function TargetRegistry:CreateScoring(fields)
	assert(fields.RunId ~= nil and fields.OwnerUserId ~= nil, "Every scoring target needs a run and an owner")
	return create(self, fields, TargetRegistry.Kind.Scoring)
end

function TargetRegistry:Get(targetId)
	return self._targets[targetId]
end

-- Drops a live target from every index. Returns nil if it was already gone, which makes every exit path
-- (claim, destruction, expiry, removal) mutually exclusive
function TargetRegistry:Remove(targetId)
	local record = self._targets[targetId]
	if not record then
		return nil
	end
	self._targets[targetId] = nil
	if record.Kind == TargetRegistry.Kind.Starter then
		local count = (self._starterCounts[record.ZoneId] or 0) - 1
		self._starterCounts[record.ZoneId] = if count > 0 then count else nil
	end
	return record
end

-- Live (unclaimed, unexpired) starters in a zone: the public cap
function TargetRegistry:CountStarters(zoneId)
	return self._starterCounts[zoneId] or 0
end

-- Read-only iteration over every live target without copying. Do not remove records inside the loop
function TargetRegistry:IterateTargets()
	return next, self._targets
end

-- Copy, safe to iterate while removing
function TargetRegistry:GetTargets()
	local list = {}
	for _, record in self._targets do
		table.insert(list, record)
	end
	return list
end

-- Runs ------------------------------------------------------------------------

function TargetRegistry:CreateRun(fields)
	assert(self._runByOwner[fields.OwnerUserId] == nil, "A player can have only one run")
	self._nextRunId += 1
	local run = table.clone(fields)
	run.RunId = self._nextRunId
	self._runs[run.RunId] = run
	self._runByOwner[run.OwnerUserId] = run
	return run
end

function TargetRegistry:GetRun(runId)
	return self._runs[runId]
end

function TargetRegistry:GetRunOf(userId)
	return self._runByOwner[userId]
end

function TargetRegistry:RemoveRun(runId)
	local run = self._runs[runId]
	if not run then
		return nil
	end
	self._runs[runId] = nil
	if self._runByOwner[run.OwnerUserId] == run then
		self._runByOwner[run.OwnerUserId] = nil
	end
	return run
end

-- Copy, safe to iterate while removing
function TargetRegistry:GetRuns()
	local list = {}
	for _, run in self._runs do
		table.insert(list, run)
	end
	return list
end

return TargetRegistry
