-- Tutorial API: personal scripted spawning sequence. run(session) runs on its own thread;
-- check session.Active after yielding. Reopening the same key replaces the old session cleanly
function EggService:OpenScriptedSession(player, key, run)
	return self._deps.tracks:Open(player, key, run)
end

function EggService:CloseScriptedSession(player, key)
	return self._deps.tracks:Close(player, key)
end

-- Tutorial API: a pickup only `player` can see as available and collect.
-- definition: { ItemTypeId: string, Amount: number, Position: Vector3, Lifetime: number? }
-- Position is the tutorial's authored spot; it is snapped to the ground below and checked for traps/clearance.
function EggService:SpawnReservedPickup(player, definition)
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
function EggService:SetCollectionEnabled(player, enabled)
	local data = self._deps.data:GetData(player)
	if not data then
		return false
	end
	data.Tutorial = data.Tutorial or {}
	data.Tutorial.OrdinaryCollectionEnabled = enabled == true
	return true
end
