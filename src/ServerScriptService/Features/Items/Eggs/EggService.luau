-- Responsibility: Floor egg record lifecycle and collection authority. Spawn requests, placement, collection,
-- expiry, removal. Records are data only: each owner's client clones and destroys its own models, so the server
-- never creates egg instances. Runner forwards Spawned/Removed to the owning player only.
-- Collected eggs go into the shared InventoryService, which owns balances; this service only manages the floor.
--
-- The server decides everything. A client collection request carries only a PickupId; the owner is the player the
-- request arrived from, and position, type, amount, and ownership always come from the record.
--
-- Collection is atomic: from the final availability check through the inventory add and the registry state
-- change nothing yields, so duplicate requests can't duplicate an award. Every later attempt finds no record.
--
-- Note: server-measured root distance is a sanity check, not teleport protection. TryCollect takes the
-- position from deps.getRootPosition so a future movement-validation layer can supply a vetted position.

local EggService = {}
EggService.__index = EggService

EggService.Reason = {
	NotFound = "NotFound",
	NotOwner = "NotOwner",
	Expired = "Expired",
	PlayerNotPresent = "PlayerNotPresent",
	ProfileNotActive = "ProfileNotActive",
	NoCharacter = "NoCharacter",
	TooFar = "TooFar",
	ZoneAccess = "ZoneAccess",
	TutorialLocked = "TutorialLocked",
	InventoryFull = "InventoryFull",
	RateLimited = "RateLimited",
	InvalidZone = "InvalidZone",
	InvalidItem = "InvalidItem",
	InvalidAmount = "InvalidAmount",
	PlayerCap = "PlayerCap",
	ZoneCap = "ZoneCap",
	PlacementRejected = "PlacementRejected",
	-- Removal reasons (Removed signal)
	Collected = "Collected",
	ZoneRemoved = "ZoneRemoved",
	Removed = "Removed",
	OwnerLeft = "OwnerLeft",
	Shutdown = "Shutdown",
}

local Reason = EggService.Reason

local function isWholeAmount(amount: number)
	return type(amount) == "number" and amount == amount and amount >= 1 and math.floor(amount) == amount
end

-- deps:
--   pickupConfig      Configs/Eggs/PickupConfig
--   spawnerConfig     Configs/Zones/SpawnerConfig (MaxPickups, MaxPickupsPerPlayer, TickInterval)
--   itemCatalog       Shared ItemDefintions
--   maxStack          InventoryConfig.MAX_STACK
--   registry          EggRegistry
--   placement         PickupPlacement
--   zones             ZoneService
--   inventory         InventoryService
--   data              PlayerDataService contract
--   tracks            SpawnTrackRegistry (personal scripted sessions; closed when the player leaves)
--   scheduler         { Delay: (seconds, fn) -> handle, Cancel: (handle) -> () }
--   now               () -> number
--   rng               Random-like (NextNumber, NextInteger)
--   isPlayerPresent   (Player) -> boolean
--   getRootPosition   (Player) -> Vector3?   non-yielding; nil without a living character
--   Signal
--   warn              ((string) -> ())?

function EggService.new(deps)
	return setmetatable({
		_deps = deps,
		_config = deps.pickupConfig,
		_spawnerConfig = deps.spawnerConfig,
		_items = deps.itemCatalog,
		_maxStack = deps.maxStack,
		_registry = deps.registry,
		_warn = deps.warn or warn,
		_fullNotifiedAt = {}, -- [Player] = { [ItemTypeId] = time }
		_requestWindows = {}, -- [Player] = { Start = time, Count = number }
		_destroyed = false,

		Spawned = deps.Signal.new(), -- (record)
		Collected = deps.Signal.new(), -- (player, record, newCount)
		Removed = deps.Signal.new(), -- (record, reason); every exit: collection, expiry, zone/owner removal
		InventoryFull = deps.Signal.new(), -- (player, itemTypeId); already rate-limited
	}, EggService)
end

-- Internal lifecycle ----------------------------------------------------------
function EggService:_create(fields, lifetime)
	local record = self._registry:Create(fields)

	-- The callback carries the generation it was scheduled for and does nothing if the record moved on
	local pickupId, generation = record.PickupId, record.Generation
	record.ExpiryHandle = self._deps.scheduler.Delay(lifetime, function()
		self:_onExpiryTimer(pickupId, generation)
	end)

	self.Spawned:Fire(record)
	return record
end

-- The single exit path for a live record. Returns false if something else already finished it
function EggService:_finish(record, finalState, reason)
	if not self._registry:Finish(record.PickupId, finalState) then
		return false
	end

	local handle = record.ExpiryHandle
	record.ExpiryHandle = nil
	if handle then
		self._deps.scheduler.Cancel(handle)
	end

	self.Removed:Fire(record, reason)
	return true
end

function EggService:_onExpiryTimer(pickupId, generation)
	local record = self._registry:Get(pickupId)
	if not record or record.Generation ~= generation then
		return
	end
	record.ExpiryHandle = nil -- this timer is the one running; don't cancel it from inside itself
	self:_finish(record, "Despawned", Reason.Expired)
end

-- Spawning -------------------------------------------------------------------------

-- Hard caps for one owner in one zone. Returns true, or false and the cap that blocks
function EggService:HasCapacity(userId, zoneId)
	if self._registry:CountOwner(userId) >= self._spawnerConfig.MaxPickupsPerPlayer then
		return false, Reason.PlayerCap
	end
	if self._registry:CountOwnerZone(userId, zoneId) >= self._spawnerConfig.MaxPickups then
		return false, Reason.ZoneCap
	end
	return true
end

-- One placement candidate for an ordinary egg owned by `player`. Called by ZoneSpawner, which owns retries.
function EggService:TrySpawn(player, zoneId, itemTypeId, amount)
	if self._destroyed then return nil, Reason.InvalidZone end

	local zone = self._deps.zones:GetZone(zoneId)
	if not zone then return nil, Reason.InvalidZone end

	if self._items[itemTypeId] == nil then return nil, Reason.InvalidItem end
	if not isWholeAmount(amount) or amount > self._maxStack then return nil, Reason.InvalidAmount end

	local position, placementReason = self._deps.placement:TryCandidate(zone, self._deps.rng, player.UserId)
	if not position then
		return nil, Reason.PlacementRejected, placementReason
	end

	-- Caps are confirmed last, immediately before registering, with no yield in between
	local hasCapacity, capReason = self:HasCapacity(player.UserId, zoneId)
	if not hasCapacity then
		return nil, capReason
	end

	local now = self._deps.now()
	local lifetime = self._config.PickupLifetime
	return self:_create({
		OwnerUserId = player.UserId,
		ItemTypeId = itemTypeId,
		Amount = amount,
		ZoneId = zoneId,
		Position = position,
		CreatedAt = now,
		ExpiresAt = now + lifetime,
	}, lifetime)
end

-- Seconds until the record expires, measured on the server clock only. Sent to the owner so it never
-- compares server and client clocks; the client still waits for the server's removal
function EggService:GetRemainingLifetime(record)
	return math.max(record.ExpiresAt - self._deps.now(), 0)
end

-- Tutorial gate ------------------------------------------------------------------
-- Ordinary collection is refused while the saved Tutorial.OrdinaryCollectionEnabled flag is false.
-- PENDING: who flips the flag (SetCollectionEnabled) waits on the tutorial module boundary.
function EggService:IsOrdinaryCollectionEnabled(player)
	local data = self._deps.data:GetData(player)
	return data ~= nil and data.Tutorial ~= nil and data.Tutorial.OrdinaryCollectionEnabled == true
end

-- Collection ------------------------------------------------------------------

-- Network entry point. Drops requests over PickupConfig.CollectRequestsPerTick per SpawnerConfig.TickInterval
-- window before doing any work, then validates like TryCollect
function EggService:HandleCollectRequest(player, pickupId)
	local now = self._deps.now()
	local window = self._requestWindows[player]
	if not window or now - window.Start >= self._spawnerConfig.TickInterval then
		window = { Start = now, Count = 0 }
		self._requestWindows[player] = window
	end
	if window.Count >= self._config.CollectRequestsPerTick then
		return false, Reason.RateLimited
	end
	window.Count += 1
	return self:TryCollect(player, pickupId)
end

-- Validates and commits one collection attempt. Returns true, newCount or false, reason. Never yields.
function EggService:TryCollect(player, pickupId)
	local deps = self._deps
	local record = self._registry:Get(pickupId)

	if not record or not self._registry.IsCollectible(record) then return false, Reason.NotFound end
	-- Ownership first: another player's request must never change someone else's egg, not even by expiring it
	if record.OwnerUserId ~= player.UserId then return false, Reason.NotOwner end

	-- A late or skipped expiry timer must not leave a collectable egg behind
	if deps.now() >= record.ExpiresAt then
		self:_finish(record, "Despawned", Reason.Expired)
		return false, Reason.Expired
	end

	if not deps.isPlayerPresent(player) then return false, Reason.PlayerNotPresent end
	if not deps.data:IsActive(player) then return false, Reason.ProfileNotActive end
	local rootPosition = deps.getRootPosition(player)
	if not rootPosition then return false, Reason.NoCharacter end
	if (rootPosition - record.Position).Magnitude > self._config.CollectRadius then return false, Reason.TooFar end

	if not deps.zones:CanAccess(player, record.ZoneId) then
		return false, Reason.ZoneAccess
	end
	if not self:IsOrdinaryCollectionEnabled(player) then
		return false, Reason.TutorialLocked
	end

	if not deps.inventory:CanAdd(player, record.ItemTypeId, record.Amount) then
		-- The egg stays exactly as it was
		self:_notifyFull(player, record.ItemTypeId)
		return false, Reason.InventoryFull
	end

	-- Commit. No yields from here to the end of the function
	local added, newCount = deps.inventory:TryAdd(player, record.ItemTypeId, record.Amount)
	if not added then return false, Reason.InventoryFull end

	self:_finish(record, "Collected", Reason.Collected)
	self.Collected:Fire(player, record, newCount)
	return true, newCount
end

-- Client Utils ---------------------------------------------------------------------
function EggService:_notifyFull(player, itemTypeId)
	local now = self._deps.now()
	local byItem = self._fullNotifiedAt[player]
	if not byItem then
		byItem = {}
		self._fullNotifiedAt[player] = byItem
	end
	local last = byItem[itemTypeId]
	if last and now - last < self._config.InventoryFullCooldown then
		return
	end
	byItem[itemTypeId] = now
	self.InventoryFull:Fire(player, itemTypeId)
end

-- Removal ---------------------------------------------------------------------

function EggService:Despawn(pickupId, reason)
	local record = self._registry:Get(pickupId)
	return record ~= nil and self:_finish(record, "Despawned", reason or Reason.Removed)
end

function EggService:RemoveZonePickups(zoneId)
	for _, record in self._registry:GetInZone(zoneId) do
		self:_finish(record, "Despawned", Reason.ZoneRemoved)
	end
end

-- Expires anything past ExpiresAt. Safety net beside the per-egg timers
function EggService:ExpireDue()
	local now = self._deps.now()
	for _, record in self._registry:GetAll() do
		if now >= record.ExpiresAt then
			self:_finish(record, "Despawned", Reason.Expired)
		end
	end
end

-- Removes every record the player owns. Idempotent: Runner calls it on Releasing and again on PlayerRemoving
function EggService:OnPlayerRemoving(player)
	for _, record in self._registry:GetOwnedBy(player.UserId) do
		self:_finish(record, "Despawned", Reason.OwnerLeft)
	end
	self._deps.tracks:CloseAll(player)
	self._fullNotifiedAt[player] = nil
	self._requestWindows[player] = nil
end

function EggService:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._deps.tracks:Destroy()
	for _, record in self._registry:GetAll() do
		self:_finish(record, "Despawned", Reason.Shutdown)
	end
	self.Spawned:DisconnectAll()
	self.Collected:DisconnectAll()
	self.Removed:DisconnectAll()
	self.InventoryFull:DisconnectAll()
end

return EggService
