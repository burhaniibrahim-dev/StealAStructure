-- Responsibility: Pure zone geometry. Point-in-zone tests, highest-priority lookup, and candidate sampling.
-- Never yields and never touches characters: callers pass positions in.
--
-- Vertical policy (explicit, per zone via the VerticalMode attribute):
--   "Column" (default) - the zone is an infinite vertical column; world height is ignored.
--                        Zone parts can hover above the ground they cover.
--   "Volume"           - the point must also lie inside the part's vertical extent.
-- Block zones use object Y as their vertical axis; Cylinder zones use object X (the cylinder axis).
-- ZoneService rejects zones whose vertical axis isn't aligned with world up, which keeps "ignore height" exact.

local ZoneDetection = {}

-- |axis.Y| a zone's vertical axis must reach to count as upright (about 2.5 degrees of tilt)
ZoneDetection.VERTICAL_ALIGNMENT = 0.999

local function halfHeight(zone)
	return if zone.Shape == "Cylinder" then zone.Size.X / 2 else zone.Size.Y / 2
end

function ZoneDetection.Contains(zone, point: Vector3): boolean
	local localPoint = zone.CFrame:PointToObjectSpace(point)
	local size = zone.Size

	if zone.Shape == "Cylinder" then
		if zone.VerticalMode == "Volume" and math.abs(localPoint.X) > size.X / 2 then
			return false
		end
		local radius = math.min(size.Y, size.Z) / 2
		return localPoint.Y * localPoint.Y + localPoint.Z * localPoint.Z <= radius * radius
	end

	if zone.VerticalMode == "Volume" and math.abs(localPoint.Y) > size.Y / 2 then
		return false
	end
	return math.abs(localPoint.X) <= size.X / 2 and math.abs(localPoint.Z) <= size.Z / 2
end

-- Returns the containing zone with the highest Priority (nil when outside every zone).
-- Equal priorities are an authoring error; they resolve by ZoneId so the answer is deterministic,
-- and the second return value reports that a tie happened so the caller can warn.
function ZoneDetection.Find(point: Vector3?, zones)
	if point == nil then
		return nil, false
	end

	local best = nil
	local tied = false
	for _, zone in zones do
		if not ZoneDetection.Contains(zone, point) then
			continue
		end
		if best == nil or zone.Priority > best.Priority then
			best = zone
			tied = false
		elseif zone.Priority == best.Priority then
			tied = true
			if zone.ZoneId < best.ZoneId then
				best = zone
			end
		end
	end
	return best, tied
end

-- Uniform random point on the zone's horizontal cross-section, at the zone's centre height
function ZoneDetection.SampleHorizontal(zone, rng): Vector3
	local size = zone.Size
	local localPoint
	if zone.Shape == "Cylinder" then
		-- sqrt keeps the distribution uniform over the disc instead of clustering at the centre
		local radius = math.min(size.Y, size.Z) / 2 * math.sqrt(rng:NextNumber())
		local angle = rng:NextNumber() * 2 * math.pi
		localPoint = Vector3.new(0, radius * math.cos(angle), radius * math.sin(angle))
	else
		localPoint = Vector3.new(rng:NextNumber(-size.X / 2, size.X / 2), 0, rng:NextNumber(-size.Z / 2, size.Z / 2))
	end
	return zone.CFrame:PointToWorldSpace(localPoint)
end

function ZoneDetection.TopY(zone): number
	return zone.CFrame.Position.Y + halfHeight(zone)
end

function ZoneDetection.BottomY(zone): number
	return zone.CFrame.Position.Y - halfHeight(zone)
end

return ZoneDetection
