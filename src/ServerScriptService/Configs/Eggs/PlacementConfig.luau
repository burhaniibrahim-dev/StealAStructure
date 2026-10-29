-- Responsibility: Geometry rules for evaluating one egg placement candidate (PickupPlacement).
-- Retries belong to scheduling: see Configs/Zones/SpawnerConfig.PlacementAttempts. Distances are studs.
local Placement = {
		RaycastHeight = 40, -- ray starts this far above the zone top
		RaycastDepth = 200, -- and searches this far below the zone bottom
		AnchorRaycastHeight = 3, -- rays from authored anchors start this far above the anchor
		SurfaceOffset = 1, -- pickup centre above the ground hit
		MaxSlopeDegrees = 35,
		ForbiddenMaterials = { "Water", "CrackedLava", "ForceField" }, -- Enum.Material names
		PickupClearance = 4, -- from the same owner's other eggs (other players' eggs are invisible to this owner)
		CharacterClearance = 5, -- from any character root
		ObstructionRadius = 1, -- pickup centre must not overlap parts
		ExclusionPadding = 3, -- around parts tagged PickupExclusion (structures, interaction points)

		--TrapPadding = 4, -- around active traps
}

return Placement
