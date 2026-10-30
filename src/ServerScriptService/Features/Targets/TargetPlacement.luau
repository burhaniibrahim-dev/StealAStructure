-- Responsibility: Server-side position validation for targets. Evaluates exactly one candidate per call; TargetService
-- bounds how many candidates a batch may try.
--
-- Per candidate: sample a horizontal point -> GroundProbe (same ground rules as eggs) -> the landing point's
-- highest-priority zone must be the requested zone (never an adjacent, nested, or locked zone) -> 3D clearance ->
-- obstruction probe -> PickupExclusion volumes (structures, interaction points).
-- Targets sit flush: position = ground hit + TargetConfig.SurfaceOffset (0), and models are pivoted at their base.
--
-- Clearance (full 3D distance; eggs need TargetConfig.EggClearance, other targets TargetConfig.Clearance):
--   Public starter   every live egg (all owners), every live starter, every live scoring target
--   Scoring target   the run owner's live eggs only (other players' eggs are invisible to them), every live
--                    starter, every live scoring target (all runs, including ones awaiting acknowledgment)
-- Egg placement applies the same EggClearance the other way (Runner.Eggs: a PointProvider over live targets).
-- Only live registry records count. A claimed or destroyed entity leaves the registry before its exit animation,
-- and the next scoring target is placed only after that, so nothing ever blocks its own replacement.
--
-- world interface (RobloxPickupWorld): world:IsSpaceBlocked(position, radius, ignore) -> boolean

local TargetPlacement = {}
TargetPlacement.__index = TargetPlacement

TargetPlacement.Reason = {
	OutsideZone = "OutsideZone",
	OutsideRadius = "OutsideRadius",
	NearEgg = "NearEgg",
	NearTarget = "NearTarget",
	Obstructed = "Obstructed",
	Excluded = "Excluded",
	-- plus GroundProbe.Reason
}

local Reason = TargetPlacement.Reason

-- deps:
--   config            Configs/Targets/TargetConfig (Clearance, EggClearance, SurfaceOffset)
--   placementConfig   Configs/Eggs/PlacementConfig (RaycastHeight, RaycastDepth, ObstructionRadius, ExclusionPadding)
--   ground            GroundProbe
--   detection         ZoneDetection
--   getZones          () -> { zone }   every registered zone, for the highest-priority check
--   world             { IsSpaceBlocked }
--   eggRegistry       EggRegistry
--   targetRegistry    TargetRegistry
--   exclusions        { provider }?
function TargetPlacement.new(deps)
	return setmetatable({
		_config = deps.config,
		_placementConfig = deps.placementConfig,
		_ground = deps.ground,
		_detection = deps.detection,
		_getZones = deps.getZones,
		_world = deps.world,
		_eggs = deps.eggRegistry,
		_targets = deps.targetRegistry,
		_exclusions = deps.exclusions or {},
	}, TargetPlacement)
end

-- Horizontal area of a zone's cross-section
function TargetPlacement.ZoneArea(zone)
	local size = zone.Size
	if zone.Shape == "Cylinder" then
		local radius = math.min(size.Y, size.Z) / 2
		return math.pi * radius * radius
	end
	return size.X * size.Z
end

local function horizontalDistance(a, b)
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- One public starter candidate anywhere in `zone`. Returns position or nil, reason
function TargetPlacement:TryStarter(zone, rng)
	return self:ValidateAt(self._detection.SampleHorizontal(zone, rng), zone, nil)
end

-- One scoring target candidate for a run: uniform over (disk of `radius` around `origin`, horizontally) ∩ zone.
-- Samples from whichever of the two is smaller and rejects points outside the other, which keeps the result uniform
-- over the intersection and wastes as few candidates as possible. Returns position or nil, reason
function TargetPlacement:TryRun(zone, origin, radius, ownerUserId, rng)
	local point
	if math.pi * radius * radius <= TargetPlacement.ZoneArea(zone) then
		-- sqrt keeps the distribution uniform over the disc instead of clustering at the centre
		local distance = radius * math.sqrt(rng:NextNumber())
		local angle = rng:NextNumber() * 2 * math.pi
		point = origin + Vector3.new(distance * math.cos(angle), 0, distance * math.sin(angle))
	else
		point = self._detection.SampleHorizontal(zone, rng)
		if horizontalDistance(point, origin) > radius then
			return nil, Reason.OutsideRadius
		end
	end
	return self:ValidateAt(point, zone, ownerUserId)
end

-- Validates the ground below the horizontal `point`. eggOwnerUserId nil = public starter (every egg counts),
-- otherwise only that owner's eggs count
function TargetPlacement:ValidateAt(point, zone, eggOwnerUserId)
	local placement = self._placementConfig
	local topY = self._detection.TopY(zone) + placement.RaycastHeight
	local bottomY = self._detection.BottomY(zone) - placement.RaycastDepth
	local hit, groundReason = self._ground:Probe(Vector3.new(point.X, topY, point.Z), topY - bottomY)
	if not hit then
		return nil, groundReason
	end

	local position = hit.Position + Vector3.new(0, self._config.SurfaceOffset, 0)
	local owner = self._detection.Find(position, self._getZones())
	if not owner or owner.ZoneId ~= zone.ZoneId then
		return nil, Reason.OutsideZone
	end

	local eggClearance = self._config.EggClearance
	local iterateEggs, eggs
	if eggOwnerUserId == nil then
		iterateEggs, eggs = self._eggs:IterateAll()
	else
		iterateEggs, eggs = self._eggs:IterateOwnedBy(eggOwnerUserId)
	end
	for _, egg in iterateEggs, eggs do
		if (egg.Position - position).Magnitude < eggClearance then
			return nil, Reason.NearEgg
		end
	end
	local clearance = self._config.Clearance
	for _, target in self._targets:IterateTargets() do
		if (target.Position - position).Magnitude < clearance then
			return nil, Reason.NearTarget
		end
	end

	-- Probe just above the ground, ignoring the ground itself, so the floor never counts as an obstruction
	local probe = hit.Position + Vector3.new(0, placement.ObstructionRadius + 0.1, 0)
	if self._world:IsSpaceBlocked(probe, placement.ObstructionRadius, hit.Instance) then
		return nil, Reason.Obstructed
	end
	for _, provider in self._exclusions do
		if provider:IsExcluded(position, placement.ExclusionPadding) then
			return nil, Reason.Excluded
		end
	end
	return position
end

return TargetPlacement
