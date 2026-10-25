-- Responsibility: Floor pickup lifecycle. Spawn requests, placement, model creation, collection, expiry, removal.
-- The server decides everything: clients never send positions, amounts, rarities, or pickup ids for grants.
--
-- Collection is atomic: from the final availability check through the inventory add and the registry state
-- change nothing yields, so repeated touches, several body parts, and simultaneous players can't duplicate
-- a pickup. The first valid server-processed collection wins; every later attempt finds no record.
--
-- Note: server-measured root distance is a sanity check, not teleport protection. TryCollect takes the
-- position from deps.getRootPosition so a future movement-validation layer can supply a vetted position.

local ItemService = {}
ItemService.__index = ItemService

ItemService.Reason = {
	NotFound = "NotFound",
	Expired = "Expired",
	PlayerNotPresent = "PlayerNotPresent",
	ProfileNotActive = "ProfileNotActive",
	NoCharacter = "NoCharacter",
	TooFar = "TooFar",
	ZoneAccess = "ZoneAccess",
	ReservedForOther = "ReservedForOther",
	TutorialLocked = "TutorialLocked",
	InventoryFull = "InventoryFull",
	InvalidZone = "InvalidZone",
	InvalidItem = "InvalidItem",
	InvalidAmount = "InvalidAmount",
	InvalidDefinition = "InvalidDefinition",
	ZoneBudget = "ZoneBudget",
	ServerBudget = "ServerBudget",
	ReservedLimit = "ReservedLimit",
	PlacementRejected = "PlacementRejected",
	ModelFailed = "ModelFailed",
}

local Reason = ItemService.Reason

local function isWholeAmount(amount)
	return type(amount) == "number" and amount == amount and amount >= 1 and math.floor(amount) == amount
end

-- deps:
--   config            PickupConfig
--   itemDefinitions   shared ItemDefinitions
--   registry          ItemRegistry
--   placement         PickupPlacement
--   detection         ZoneDetection
--   zones             ZoneService
--   inventory         InventoryService
--   data              PlayerDataService contract
--   analytics         PickupAnalytics
--   tracks            SpawnTrackRegistry (personal tutorial sessions)
--   models            { Create: (record) -> (cleanup: () -> ())? }
--   scheduler         { Delay: (seconds, fn) -> handle, Cancel: (handle) -> () }
--   now               () -> number
--   rng               Random-like (NextNumber, NextInteger)
--   getPlayers        () -> {Player}
--   isPlayerPresent   (Player) -> boolean
--   getRootPosition   (Player) -> Vector3?   non-yielding; nil without a living character
--   Signal
--   warn              ((string) -> ())?

function ItemService.new(deps)
	return setmetatable({
		_deps = deps,
		_config = deps.config,
		_items = deps.itemDefinitions.Items,
		_maxStack = deps.itemDefinitions.MAX_STACK,
		_registry = deps.registry,
		_warn = deps.warn or warn,
		_fullNotifiedAt = {}, -- [Player] = { [ItemTypeId] = time }
		_destroyed = false,

		Spawned = deps.Signal.new(), -- (record)
		Collected = deps.Signal.new(), -- (player, record, newCount)
		Despawned = deps.Signal.new(), -- (record, reason)
		InventoryFull = deps.Signal.new(), -- (player, itemTypeId); already rate-limited
	}, ItemService)
end

-- Internal lifecycle ----------------------------------------------------------

function ItemService:_create(fields, lifetime)
	local record = self._registry:Create(fields)

	local ok, cleanupOrError = pcall(self._deps.models.Create, record)
	if not ok then
		self._registry:Finish(record.PickupId, "Despawned")
		self._warn(`[ItemService] Pickup model creation failed: {cleanupOrError}`)
		return nil, Reason.ModelFailed
	end
	record.Cleanup = cleanupOrError

	-- The callback carries the generation it was scheduled for and does nothing if the record moved on
	local pickupId, generation = record.PickupId, record.Generation
	record.ExpiryHandle = self._deps.scheduler.Delay(lifetime, function()
		self:_onExpiryTimer(pickupId, generation)
	end)

	self.Spawned:Fire(record)
	return record
end

-- The single exit path for a live record. Returns false if something else already finished it
function ItemService:_finish(record, finalState, reason)
	if not self._registry:Finish(record.PickupId, finalState) then
		return false
	end

	local handle = record.ExpiryHandle
	record.ExpiryHandle = nil
	if handle then
		self._deps.scheduler.Cancel(handle)
	end

	local cleanup = record.Cleanup
	record.Cleanup = nil
	if cleanup then
		local ok, err = pcall(cleanup)
		if not ok then
			self._warn(`[ItemService] Pickup cleanup failed: {err}`)
		end
	end

	if finalState == "Despawned" then
		self.Despawned:Fire(record, reason)
	end
	return true
end

function ItemService:_onExpiryTimer(pickupId, generation)
	local record = self._registry:Get(pickupId)
	if not record or record.Generation ~= generation then
		return
	end
	record.ExpiryHandle = nil -- this timer is the one running; don't cancel it from inside itself
	self:_finish(record, "Despawned", Reason.Expired)
end

function ItemService:_notifyFull(player, itemTypeId)
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

-- Spawning -------------------------------------------------------------------------

-- One placement candidate for an ordinary pickup. Called by ZoneSpawner, which owns retries.
-- zoneBudget is the population-aware cap ZoneSpawner computed for this zone right now.
function ItemService:TrySpawnOrdinary(zoneId, itemTypeId, amount, zoneBudget)
	if self._destroyed then
		return nil, Reason.InvalidZone
	end
	local zone = self._deps.zones:GetZone(zoneId)
	if not zone then
		return nil, Reason.InvalidZone
	end
	if self._items[itemTypeId] == nil then
		return nil, Reason.InvalidItem
	end
	if not isWholeAmount(amount) or amount > self._maxStack then
		return nil, Reason.InvalidAmount
	end

	local position, placementReason = self._deps.placement:TryCandidate(zone, self._deps.rng)
	if not position then
		return nil, Reason.PlacementRejected, placementReason
	end

	-- Budgets are confirmed last, immediately before registering, with no yield in between
	if self._registry:CountZone(zoneId) >= zoneBudget then
		return nil, Reason.ZoneBudget
	end
	if self._registry:CountOrdinary() >= self._config.ServerMaxPickups then
		return nil, Reason.ServerBudget
	end

	local now = self._deps.now()
	return self:_create({
		ItemTypeId = itemTypeId,
		Amount = amount,
		ZoneId = zoneId,
		Position = position,
		CreatedAt = now,
		ExpiresAt = now + self._config.PickupLifetime,
	}, self._config.PickupLifetime)
end

-- Tutorial API: a pickup only `player` can see as available and collect.
-- definition: { ItemTypeId: string, Amount: number, Position: Vector3, Lifetime: number? }
-- Position is the tutorial's authored spot; it is snapped to the ground below and checked for traps/clearance.
function ItemService:SpawnReservedPickup(player, definition)
	if self._destroyed then
		return nil, Reason.PlayerNotPresent
	end
	if type(definition) ~= "table" or typeof(definition.Position) ~= "Vector3" then
		return nil, Reason.InvalidDefinition
	end
	if self._items[definition.ItemTypeId] == nil then
		return nil, Reason.InvalidItem
	end
	local tutorialConfig = self._config.Tutorial
	local amount = definition.Amount
	if not isWholeAmount(amount) or amount > tutorialConfig.MaxReservedAmount or amount > self._maxStack then
		return nil, Reason.InvalidAmount
	end
	if not self._deps.isPlayerPresent(player) then
		return nil, Reason.PlayerNotPresent
	end
	if not self._deps.data:IsActive(player) then
		return nil, Reason.ProfileNotActive
	end
	if self._registry:CountReserved(player.UserId) >= tutorialConfig.MaxReservedPerPlayer then
		return nil, Reason.ReservedLimit
	end

	local placementConfig = self._config.Placement
	local origin = definition.Position + Vector3.new(0, placementConfig.AnchorRaycastHeight, 0)
	local position, placementReason =
		self._deps.placement:Validate(origin, placementConfig.AnchorRaycastHeight + placementConfig.RaycastDepth, nil)
	if not position then
		return nil, Reason.PlacementRejected, placementReason
	end

	local zone = self._deps.detection.Find(position, self._deps.zones:GetZones())
	local lifetime = definition.Lifetime or tutorialConfig.ReservedLifetime
	local now = self._deps.now()
	return self:_create({
		ItemTypeId = definition.ItemTypeId,
		Amount = amount,
		ZoneId = zone and zone.ZoneId,
		Position = position,
		CreatedAt = now,
		ExpiresAt = now + lifetime,
		ReservedUserId = player.UserId,
	}, lifetime)
end

-- Tutorial API: server-side gate for ordinary pickups. Saved in the profile
function ItemService:SetCollectionEnabled(player, enabled)
	local data = self._deps.data:GetData(player)
	if not data then
		return false
	end
	data.Tutorial = data.Tutorial or {}
	data.Tutorial.OrdinaryCollectionEnabled = enabled == true
	return true
end

function ItemService:IsOrdinaryCollectionEnabled(player)
	local data = self._deps.data:GetData(player)
	return data ~= nil and data.Tutorial ~= nil and data.Tutorial.OrdinaryCollectionEnabled == true
end

-- Tutorial API
function ItemService:RemoveReservedPickups(player)
	for _, record in self._registry:GetReservedFor(player.UserId) do
		self:_finish(record, "Despawned", "ReservationCleared")
	end
end

-- Tutorial API: personal scripted spawning sequence. run(session) runs on its own thread;
-- check session.Active after yielding. Reopening the same key replaces the old session cleanly
function ItemService:OpenScriptedSession(player, key, run)
	return self._deps.tracks:Open(player, key, run)
end

function ItemService:CloseScriptedSession(player, key)
	return self._deps.tracks:Close(player, key)
end

-- Collection ------------------------------------------------------------------

-- Validates and commits one collection attempt. Every call is a candidate; most will be rejected.
-- Returns true, newCount or false, reason. Never yields.
function ItemService:TryCollect(player, pickupId)
	local deps = self._deps
	local record = self._registry:Get(pickupId)
	if not record or not self._registry.IsCollectible(record) then
		return false, Reason.NotFound
	end

	-- A late or skipped expiry timer must not leave a collectable egg behind
	if deps.now() >= record.ExpiresAt then
		self:_finish(record, "Despawned", Reason.Expired)
		return false, Reason.Expired
	end

	if not deps.isPlayerPresent(player) then
		return false, Reason.PlayerNotPresent
	end
	if not deps.data:IsActive(player) then
		return false, Reason.ProfileNotActive
	end
	local rootPosition = deps.getRootPosition(player)
	if not rootPosition then
		return false, Reason.NoCharacter
	end
	if (rootPosition - record.Position).Magnitude > self._config.CollectRadius then
		return false, Reason.TooFar
	end
	if record.ZoneId and not deps.zones:CanAccess(player, record.ZoneId) then
		return false, Reason.ZoneAccess
	end

	if record.ReservedUserId then
		if record.ReservedUserId ~= player.UserId then
			return false, Reason.ReservedForOther
		end
	elseif not self:IsOrdinaryCollectionEnabled(player) then
		return false, Reason.TutorialLocked
	end

	if not deps.inventory:CanAdd(player, record.ItemTypeId, record.Amount) then
		-- The pickup stays exactly as it was
		self:_notifyFull(player, record.ItemTypeId)
		return false, Reason.InventoryFull
	end

	-- Commit. No yields from here to the end of the function
	local added, newCount = deps.inventory:TryAdd(player, record.ItemTypeId, record.Amount)
	if not added then
		return false, Reason.InventoryFull
	end
	self:_finish(record, "Collected")
	deps.analytics:RecordCollection(player, record)
	self.Collected:Fire(player, record, newCount)
	return true, newCount
end

-- Touch signal from the pickup's hitbox (already resolved to a player by the Roblox adapter)
function ItemService:HandleTouch(pickupId, player)
	return self:TryCollect(player, pickupId)
end

-- Catches players standing still on a pickup (e.g. after their full stack frees up), where Touched won't refire
function ItemService:SweepProximity()
	local sweepRadius = self._config.SweepRadius
	for _, player in self._deps.getPlayers() do
		local rootPosition = self._deps.getRootPosition(player)
		if not rootPosition then
			continue
		end
		local candidates = self._registry:GetReservedFor(player.UserId)
		local zoneId = self._deps.zones:GetZoneOf(player)
		if zoneId then
			for _, record in self._registry:GetInZone(zoneId) do
				table.insert(candidates, record)
			end
		end
		for _, record in candidates do
			if (record.Position - rootPosition).Magnitude <= sweepRadius then
				self:TryCollect(player, record.PickupId)
			end
		end
	end
end

-- Removal ---------------------------------------------------------------------

function ItemService:Despawn(pickupId, reason)
	local record = self._registry:Get(pickupId)
	return record ~= nil and self:_finish(record, "Despawned", reason or "Removed")
end

function ItemService:RemoveZonePickups(zoneId)
	for _, record in self._registry:GetInZone(zoneId) do
		self:_finish(record, "Despawned", "ZoneRemoved")
	end
end

-- Expires anything past ExpiresAt. Safety net beside the per-pickup timers
function ItemService:ExpireDue()
	local now = self._deps.now()
	for _, record in self._registry:GetAll() do
		if now >= record.ExpiresAt then
			self:_finish(record, "Despawned", Reason.Expired)
		end
	end
end

function ItemService:OnPlayerRemoving(player)
	self:RemoveReservedPickups(player)
	self._deps.tracks:CloseAll(player)
	self._fullNotifiedAt[player] = nil
end

function ItemService:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._deps.tracks:Destroy()
	for _, record in self._registry:GetAll() do
		self:_finish(record, "Despawned", "Shutdown")
	end
	self.Spawned:DisconnectAll()
	self.Collected:DisconnectAll()
	self.Despawned:DisconnectAll()
	self.InventoryFull:DisconnectAll()
end

return ItemService
