-- Responsibility: Active floor pickup records and their indexes. No gameplay rules, no Roblox instances.
-- A record leaves the registry the moment it is Collected or Despawned, so only live pickups are stored.
-- PickupIds are server-issued, increasing, and never reused; an inventory ItemTypeId is never an entity id.
--
-- Record fields:
--   PickupId, ItemTypeId, Amount, ZoneId?, Position, CreatedAt, ExpiresAt, ReservedUserId?,
--   State ("Available" | "Reserved" | "Collected" | "Despawned"),
--   Generation (bumped on every state change; delayed callbacks compare it before acting),
--   Model / Cleanup (owned by ItemService's model factory), ExpiryHandle

local ItemRegistry = {}
ItemRegistry.__index = ItemRegistry

ItemRegistry.State = {
	Available = "Available",
	Reserved = "Reserved",
	Collected = "Collected",
	Despawned = "Despawned",
}

function ItemRegistry.new()
	return setmetatable({
		_nextId = 0,
		_byId = {},
		_byZone = {}, -- [ZoneId] = { [PickupId] = record }  (ordinary and reserved)
		_ordinaryByZone = {}, -- [ZoneId] = count, ordinary only (reserved pickups don't spend zone budget)
		_byReserved = {}, -- [UserId] = { [PickupId] = record }
		_reservedCounts = {}, -- [UserId] = count
		_ordinaryCount = 0,
		_count = 0,
	}, ItemRegistry)
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

function ItemRegistry:Create(fields)
	self._nextId += 1
	local record = {
		PickupId = self._nextId,
		ItemTypeId = fields.ItemTypeId,
		Amount = fields.Amount,
		ZoneId = fields.ZoneId,
		Position = fields.Position,
		CreatedAt = fields.CreatedAt,
		ExpiresAt = fields.ExpiresAt,
		ReservedUserId = fields.ReservedUserId,
		State = if fields.ReservedUserId then ItemRegistry.State.Reserved else ItemRegistry.State.Available,
		Generation = 1,
		Model = nil,
		Cleanup = nil,
		ExpiryHandle = nil,
	}

	self._byId[record.PickupId] = record
	self._count += 1
	if record.ZoneId then
		addTo(self._byZone, record.ZoneId, record)
	end
	if record.ReservedUserId then
		addTo(self._byReserved, record.ReservedUserId, record)
		adjust(self._reservedCounts, record.ReservedUserId, 1)
	else
		self._ordinaryCount += 1
		if record.ZoneId then
			adjust(self._ordinaryByZone, record.ZoneId, 1)
		end
	end
	return record
end

function ItemRegistry:Get(pickupId)
	return self._byId[pickupId]
end

function ItemRegistry.IsCollectible(record)
	return record.State == ItemRegistry.State.Available or record.State == ItemRegistry.State.Reserved
end

-- Moves a live record to a terminal state and drops it from every index. Returns nil if already gone,
-- which is what makes collection, expiry, and removal mutually exclusive
function ItemRegistry:Finish(pickupId, finalState)
	local record = self._byId[pickupId]
	if not record then
		return nil
	end
	assert(
		finalState == ItemRegistry.State.Collected or finalState == ItemRegistry.State.Despawned,
		"Finish needs a terminal state"
	)

	record.State = finalState
	record.Generation += 1
	self._byId[pickupId] = nil
	self._count -= 1
	if record.ZoneId then
		removeFrom(self._byZone, record.ZoneId, record)
	end
	if record.ReservedUserId then
		removeFrom(self._byReserved, record.ReservedUserId, record)
		adjust(self._reservedCounts, record.ReservedUserId, -1)
	else
		self._ordinaryCount -= 1
		if record.ZoneId then
			adjust(self._ordinaryByZone, record.ZoneId, -1)
		end
	end
	return record
end

-- Ordinary pickups in a zone (the zone budget)
function ItemRegistry:CountZone(zoneId)
	return self._ordinaryByZone[zoneId] or 0
end

function ItemRegistry:CountOrdinary()
	return self._ordinaryCount
end

function ItemRegistry:CountReserved(userId)
	return self._reservedCounts[userId] or 0
end

function ItemRegistry:Count()
	return self._count
end

local function toList(bucket)
	local list = {}
	for _, record in bucket or {} do
		table.insert(list, record)
	end
	return list
end

-- The list functions return copies, safe to iterate while finishing records
function ItemRegistry:GetInZone(zoneId)
	return toList(self._byZone[zoneId])
end

function ItemRegistry:GetReservedFor(userId)
	return toList(self._byReserved[userId])
end

function ItemRegistry:GetAll()
	return toList(self._byId)
end

-- Read-only iteration over every live record without copying. Do not finish records inside the loop
function ItemRegistry:Iterate()
	return pairs(self._byId)
end

return ItemRegistry
