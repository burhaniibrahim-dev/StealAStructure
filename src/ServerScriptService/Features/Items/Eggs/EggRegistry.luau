-- Responsibility: Authoritative floor egg records and their indexes. No gameplay rules, no Roblox instances.
-- Every egg belongs to exactly one owner, and only that owner's client renders it. A record leaves the registry
-- the moment it is Collected or Despawned, so only live eggs are stored.
-- PickupIds are server-issued, increasing, and never reused; an inventory ItemTypeId is never an entity id.
--
-- Record fields:
--   PickupId, OwnerUserId, ItemTypeId, Amount, ZoneId, Position, CreatedAt, ExpiresAt,
--   State ("Available" | "Collected" | "Despawned"),
--   Generation (bumped on every state change; delayed callbacks compare it before acting),
--   ExpiryHandle (owned by EggService)

local EggRegistry = {}
EggRegistry.__index = EggRegistry

EggRegistry.State = {
	Available = "Available",
	Collected = "Collected",
	Despawned = "Despawned",
}

local EMPTY = table.freeze({})

function EggRegistry.new()
	return setmetatable({
		_nextId = 0,
		_byId = {},
		_byOwner = {}, -- [UserId] = { [PickupId] = record }
		_byZone = {}, -- [ZoneId] = { [PickupId] = record }  (every owner)
		_ownerCounts = {}, -- [UserId] = count
		_ownerZoneCounts = {}, -- [UserId] = { [ZoneId] = count }
		_count = 0,
	}, EggRegistry)
end

local function addTo(index, key, record)
	local bucket = index[key]
	if not bucket then
		bucket = {}
		index[key] = bucket
	end
	bucket[record.PickupId] = record
end

local function removeFrom(index, key, record)
	local bucket = index[key]
	if bucket then
		bucket[record.PickupId] = nil
		if next(bucket) == nil then
			index[key] = nil
		end
	end
end

local function adjust(counts, key, delta)
	local value = (counts[key] or 0) + delta
	counts[key] = if value > 0 then value else nil
end

local function adjustOwnerZone(self, userId, zoneId, delta)
	local byZone = self._ownerZoneCounts[userId]
	if not byZone then
		byZone = {}
		self._ownerZoneCounts[userId] = byZone
	end
	adjust(byZone, zoneId, delta)
	if next(byZone) == nil then
		self._ownerZoneCounts[userId] = nil
	end
end

-- fields: OwnerUserId, ItemTypeId, Amount, ZoneId, Position, CreatedAt, ExpiresAt
function EggRegistry:Create(fields)
	assert(fields.OwnerUserId ~= nil, "Every egg needs an OwnerUserId")
	assert(fields.ZoneId ~= nil, "Every egg needs a ZoneId")
	self._nextId += 1
	local record = {
		PickupId = self._nextId,
		OwnerUserId = fields.OwnerUserId,
		ItemTypeId = fields.ItemTypeId,
		Amount = fields.Amount,
		ZoneId = fields.ZoneId,
		Position = fields.Position,
		CreatedAt = fields.CreatedAt,
		ExpiresAt = fields.ExpiresAt,
		State = EggRegistry.State.Available,
		Generation = 1,
		ExpiryHandle = nil,
	}

	self._byId[record.PickupId] = record
	self._count += 1
	addTo(self._byOwner, record.OwnerUserId, record)
	addTo(self._byZone, record.ZoneId, record)
	adjust(self._ownerCounts, record.OwnerUserId, 1)
	adjustOwnerZone(self, record.OwnerUserId, record.ZoneId, 1)
	return record
end

function EggRegistry:Get(pickupId)
	return self._byId[pickupId]
end

function EggRegistry.IsCollectible(record)
	return record.State == EggRegistry.State.Available
end

-- Moves a live record to a terminal state and drops it from every index. Returns nil if already gone,
-- which is what makes collection, expiry, and removal mutually exclusive
function EggRegistry:Finish(pickupId, finalState)
	local record = self._byId[pickupId]
	if not record then
		return nil
	end
	assert(
		finalState == EggRegistry.State.Collected or finalState == EggRegistry.State.Despawned,
		"Finish needs a terminal state"
	)

	record.State = finalState
	record.Generation += 1
	self._byId[pickupId] = nil
	self._count -= 1
	removeFrom(self._byOwner, record.OwnerUserId, record)
	removeFrom(self._byZone, record.ZoneId, record)
	adjust(self._ownerCounts, record.OwnerUserId, -1)
	adjustOwnerZone(self, record.OwnerUserId, record.ZoneId, -1)
	return record
end

-- One owner's live eggs across every zone (the per-player cap)
function EggRegistry:CountOwner(userId)
	return self._ownerCounts[userId] or 0
end

-- One owner's live eggs in one zone (the per-player, per-zone cap)
function EggRegistry:CountOwnerZone(userId, zoneId)
	local byZone = self._ownerZoneCounts[userId]
	return byZone and byZone[zoneId] or 0
end

function EggRegistry:Count()
	return self._count
end

local function toList(bucket)
	local list = {}
	for _, record in bucket or EMPTY do
		table.insert(list, record)
	end
	return list
end

-- The list functions return copies, safe to iterate while finishing records
function EggRegistry:GetOwnedBy(userId)
	return toList(self._byOwner[userId])
end

function EggRegistry:GetInZone(zoneId)
	return toList(self._byZone[zoneId])
end

function EggRegistry:GetAll()
	return toList(self._byId)
end

-- Read-only iteration over one owner's live records without copying. Do not finish records inside the loop
function EggRegistry:IterateOwnedBy(userId)
	return next, self._byOwner[userId] or EMPTY
end

return EggRegistry
