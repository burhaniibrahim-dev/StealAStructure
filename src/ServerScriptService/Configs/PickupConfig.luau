-- Responsibility: Server-only, authoritative floor pickup rules. Clients never receive this file.
-- ConfigValidator checks every value at startup; the server refuses to start pickups if it is invalid.
-- Times are seconds, distances are studs.

return {
	-- Debug ----------------------------------------------------------------
	-- Prints zones, populations, and spawn outcomes to Output every N seconds. Set false before release
	DebugSpawnLog = true,
	DebugLogInterval = 5,

	-- Lifetime and supply --------------------------------------------------
	PickupLifetime = 30, -- ordinary floor eggs despawn after this long
	ServerMaxPickups = 150, -- ordinary pickups alive across the whole server

	-- Collection -----------------------------------------------------------
	PickupRadius = 3, -- touch hitbox radius (walk-over). Touch is only a candidate signal
	SweepRadius = 5, -- server proximity sweep catches players standing still on a pickup
	CollectRadius = 8, -- max server-measured HumanoidRootPart distance; tolerance for replication lag
	ProximitySweepInterval = 0.25,
	InventoryFullCooldown = 2, -- per player, per egg type

	-- Scheduling (ZoneSpawner) ---------------------------------------------
	Schedule = {
		TickInterval = 0.25,
		-- Each zone with players rolls its next spawn in this range. One timer per zone, not per player
		SpawnInterval = { Min = 1, Max = 5 },
		RatePerExtraPlayer = 0.5, -- every extra player in a zone divides the interval by (1 + 0.5 * extra)
		MaxRateMultiplier = 3,
		PopulationCap = 8, -- players beyond this add no rate or budget
	},

	-- Placement (EggService / PickupPlacement) -----------------------------
	Placement = {
		MaxAttempts = 8, -- candidates per scheduled spawn; then skip until the next opportunity
		RaycastHeight = 40, -- ray starts this far above the zone top
		RaycastDepth = 200, -- and searches this far below the zone bottom
		AnchorRaycastHeight = 3, -- rays from authored anchors start this far above the anchor
		SurfaceOffset = 1, -- pickup centre above the ground hit
		MaxSlopeDegrees = 35,
		ForbiddenMaterials = { "Water", "CrackedLava", "ForceField" }, -- Enum.Material names
		PickupClearance = 4, -- from other pickups
		CharacterClearance = 5, -- from any character root
		ObstructionRadius = 1, -- pickup centre must not overlap parts
		ExclusionPadding = 3, -- around parts tagged PickupExclusion (structures, interaction points)
		TrapPadding = 4, -- around active traps
	},

	-- Zone distributions ---------------------------------------------------
	-- Keyed by the zone part's authored ZoneId attribute.
	-- BasePickups = budget with one player; each extra player adds PickupsPerExtraPlayer up to MaxPickups.
	Zones = {
		Default = {
			BasePickups = 4,
			PickupsPerExtraPlayer = 2,
			MaxPickups = 16,
			Distribution = {
				{ ItemTypeId = "SnowEgg", Weight = 75, Amount = { Min = 1, Max = 2 } },
				{ ItemTypeId = "IceEgg", Weight = 20, Amount = { Min = 1, Max = 1 } },
				{ ItemTypeId = "AuroraEgg", Weight = 5, Amount = { Min = 1, Max = 1 } },
			},
		},
	},
	-- Zones whose ZoneId has no entry above use this profile. Set to false to keep them empty instead
	FallbackZoneProfile = "Default",

	-- Tutorial -------------------------------------------------------------
	Tutorial = {
		-- Saved default for new profiles. Set false when the tutorial ships so new players
		-- can't take ordinary pickups until their collection stage calls SetCollectionEnabled
		DefaultOrdinaryCollectionEnabled = true,
		ReservedLifetime = 300,
		MaxReservedPerPlayer = 10,
		MaxReservedAmount = 25, -- tutorial pickups may be larger than ordinary ones
	},
}
