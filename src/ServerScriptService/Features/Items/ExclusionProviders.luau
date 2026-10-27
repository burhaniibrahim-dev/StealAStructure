-- Responsibility: Spawn exclusion providers used by PickupPlacement.
--
-- Exclusion provider interface (traps, structures, interaction points all implement it):
--   provider.Name: string
--   provider.IsPlaceholder: boolean?   true when the provider exists only to fill the slot
--   provider:IsExcluded(position: Vector3, padding: number): boolean
--
-- The trap system doesn't exist yet. NoTrapsProvider fills the trap slot and excludes nothing; Runner.Eggs
-- warns at startup while it is in use, so trap avoidance is never mistaken for finished.
-- When traps ship, pass a provider over active trap volumes (VolumeProvider fits) as `traps`.

local ExclusionProviders = {}

function ExclusionProviders.NoTrapsProvider()
	return {
		Name = "NoTrapsProvider",
		IsPlaceholder = true,
		IsExcluded = function()
			return false
		end,
	}
end

local function insideExpandedBox(cframe, size, position, padding)
	local localPoint = cframe:PointToObjectSpace(position)
	return math.abs(localPoint.X) <= size.X / 2 + padding
		and math.abs(localPoint.Y) <= size.Y / 2 + padding
		and math.abs(localPoint.Z) <= size.Z / 2 + padding
end

-- getVolumes: () -> { { CFrame: CFrame, Size: Vector3 } }; queried per check so moving volumes stay correct
function ExclusionProviders.VolumeProvider(name, getVolumes)
	return {
		Name = name,
		IsExcluded = function(_, position, padding)
			for _, volume in getVolumes() do
				if insideExpandedBox(volume.CFrame, volume.Size, position, padding) then
					return true
				end
			end
			return false
		end,
	}
end

-- Roblox: bounding boxes of instances tagged `tag` (BaseParts or Models) inside `root`
function ExclusionProviders.TaggedProvider(name, collectionService, tag, root)
	return ExclusionProviders.VolumeProvider(name, function()
		local volumes = {}
		for _, instance in collectionService:GetTagged(tag) do
			if not instance:IsDescendantOf(root) then
				continue
			end
			if instance:IsA("BasePart") then
				table.insert(volumes, { CFrame = instance.CFrame, Size = instance.Size })
			elseif instance:IsA("Model") then
				local cframe, size = instance:GetBoundingBox()
				table.insert(volumes, { CFrame = cframe, Size = size })
			end
		end
		return volumes
	end)
end

return ExclusionProviders
