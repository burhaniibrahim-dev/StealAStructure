-- Responsibility: Server-side spawn position validation. Evaluates exactly one candidate per call;
-- ZoneSpawner bounds how many candidates a scheduled spawn may try, so bad geometry can't loop forever.
--
-- Per candidate: pick a point (authored anchor, else random in the zone's oriented bounds) -> raycast down
-- for ground -> reject embedded rays, forbidden materials, blocked surfaces, steep slopes -> confirm the
-- landing point is still in the zone -> clearance from the owner's own eggs, characters, and obstructions ->
-- exclusion providers (structures / interaction points) -> trap exclusion.
-- Egg clearance only counts the requesting owner's records: other players' eggs exist only on their own clients,
-- so they never take up this owner's space.
--
-- The ground step (ray, embedded, material, blocked surface, slope) is the shared GroundProbe, also used by targets.
--
-- world interface (Roblox implementation in RobloxPickupWorld):
--   world:GetCharacterPositions() -> { Vector3 }
--   world:IsSpaceBlocked(position, radius, ignore: any?) -> boolean   ignore = the ground the ray hit

local PickupPlacement = {}
PickupPlacement.__index = PickupPlacement

PickupPlacement.Reason = {
	NoGround = "NoGround",
	Embedded = "Embedded",
	ForbiddenMaterial = "ForbiddenMaterial",
	BlockedSurface = "BlockedSurface",
	TooSteep = "TooSteep",
	OutsideZone = "OutsideZone",
	NearPickup = "NearPickup",
	NearCharacter = "NearCharacter",
	Obstructed = "Obstructed",
	Excluded = "Excluded",
	Trap = "Trap",
}

-- deps: config (Configs/Eggs/PlacementConfig), detection, world, ground (GroundProbe built from the same config),
--       registry (EggRegistry), getAnchors(zoneId)?, exclusions: { provider }, traps: provider?
function PickupPlacement.new(deps)
	return setmetatable({
		_config = deps.config, -- Configs/Eggs/PlacementConfig
		_detection = deps.detection,
		_world = deps.world,
		_ground = deps.ground,
		_registry = deps.registry,
		_getAnchors = deps.getAnchors,
		_exclusions = deps.exclusions or {},
		_traps = deps.traps,
	}, PickupPlacement)
end

-- One candidate inside `zone` for the egg owner `ownerUserId`. Returns position or nil, reason
function PickupPlacement:TryCandidate(zone, rng, ownerUserId)
	local config = self._config
	local anchors = self._getAnchors and self._getAnchors(zone.ZoneId)

	if anchors and #anchors > 0 then
		local anchor = anchors[rng:NextInteger(1, #anchors)]
		local origin = anchor.Position + Vector3.new(0, config.AnchorRaycastHeight, 0)
		return self:Validate(origin, config.AnchorRaycastHeight + config.RaycastDepth, zone, ownerUserId)
	end

	local point = self._detection.SampleHorizontal(zone, rng)
	local topY = self._detection.TopY(zone) + config.RaycastHeight
	local bottomY = self._detection.BottomY(zone) - config.RaycastDepth
	return self:Validate(Vector3.new(point.X, topY, point.Z), topY - bottomY, zone, ownerUserId)
end

-- Validates the ground below `origin` for `ownerUserId`'s egg. `zone` is optional
function PickupPlacement:Validate(origin, rayLength, zone, ownerUserId)
	local config = self._config
	local Reason = PickupPlacement.Reason

	local hit, groundReason = self._ground:Probe(origin, rayLength)
	if not hit then
		return nil, groundReason -- same names as Reason.NoGround .. Reason.TooSteep
	end

	local position = hit.Position + Vector3.new(0, config.SurfaceOffset, 0)
	if zone and not self._detection.Contains(zone, position) then
		return nil, Reason.OutsideZone
	end

	for _, record in self._registry:IterateOwnedBy(ownerUserId) do
		if (record.Position - position).Magnitude < config.PickupClearance then
			return nil, Reason.NearPickup
		end
	end
	for _, characterPosition in self._world:GetCharacterPositions() do
		if (characterPosition - position).Magnitude < config.CharacterClearance then
			return nil, Reason.NearCharacter
		end
	end
	-- Probe just above the ground, ignoring the ground itself, so the floor never counts as an obstruction
	local probe = hit.Position + Vector3.new(0, config.ObstructionRadius + 0.1, 0)
	if self._world:IsSpaceBlocked(probe, config.ObstructionRadius, hit.Instance) then
		return nil, Reason.Obstructed
	end
	for _, provider in self._exclusions do
		if provider:IsExcluded(position, config.ExclusionPadding) then
			return nil, Reason.Excluded
		end
	end
	if self._traps and self._traps:IsExcluded(position, config.TrapPadding) then
		return nil, Reason.Trap
	end

	return position
end

return PickupPlacement
