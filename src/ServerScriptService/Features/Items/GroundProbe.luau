-- Responsibility: The shared ground test for spawn candidates (egg pickups and targets). One downward ray, then
-- reject embedded rays, forbidden materials, blocked surfaces (NoPickupSpawn), and steep slopes.
-- What sits on the ground (height offset, clearances, obstructions) belongs to each caller.
--
-- world interface (Roblox implementation in RobloxPickupWorld):
--   world:Raycast(origin, direction) -> { Position, Normal, Distance, Material: string, Blocked: boolean, Instance: any? }?

local GroundProbe = {}
GroundProbe.__index = GroundProbe

GroundProbe.Reason = {
	NoGround = "NoGround",
	Embedded = "Embedded",
	ForbiddenMaterial = "ForbiddenMaterial",
	BlockedSurface = "BlockedSurface",
	TooSteep = "TooSteep",
}

-- A ray that hits within this distance of its origin started inside geometry (e.g. under terrain)
local EMBEDDED_DISTANCE = 0.05

-- deps: world, maxSlopeDegrees: number, forbiddenMaterials: { Enum.Material name }
function GroundProbe.new(deps)
	local forbidden = {}
	for _, name in deps.forbiddenMaterials do
		forbidden[name] = true
	end
	return setmetatable({
		_world = deps.world,
		_forbidden = forbidden,
		_minUpDot = math.cos(math.rad(deps.maxSlopeDegrees)),
	}, GroundProbe)
end

-- Casts straight down `rayLength` studs from `origin`. Returns the hit, or nil and a Reason
function GroundProbe:Probe(origin, rayLength)
	local Reason = GroundProbe.Reason
	local hit = self._world:Raycast(origin, Vector3.new(0, -rayLength, 0))
	if not hit then
		return nil, Reason.NoGround
	end
	if hit.Distance <= EMBEDDED_DISTANCE then
		return nil, Reason.Embedded
	end
	if self._forbidden[hit.Material] then
		return nil, Reason.ForbiddenMaterial
	end
	if hit.Blocked then
		return nil, Reason.BlockedSurface
	end
	if hit.Normal.Y < self._minUpDot then
		return nil, Reason.TooSteep
	end
	return hit
end

return GroundProbe
