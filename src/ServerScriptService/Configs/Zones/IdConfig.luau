-- Responsibility: What each ZoneId spawns. A profile has two optional weighted lists:
--   Eggs     read by ZoneSpawner. ItemTypeIds must exist in Shared/Configs/ItemDefintions; Amount must fit
--            InventoryConfig.MAX_STACK. A profile without Eggs spawns no eggs
--   Targets  read by TargetSpawner (public starters). TargetTypeIds must exist in Configs/Targets/TargetConfig.Types,
--            or be "Nothing" (a roll that spawns nothing). A profile without Targets spawns no starters.
--            Health / Scale / RadiusGrowth are locked into a run when its starter is claimed:
--              Health        whole {Min, Max}: the first scoring target's health
--              Scale         whole {Min, Max}: after each destruction, next health = previous max health * roll
--              RadiusGrowth  decimal {Min, Max}: after each destruction, spawn radius *= roll (until the growth limit)
local ZoneIdData = {
	FallbackZoneProfile = "Default",-- Zones whose ZoneId has no entry in Zones use this profile (false = no spawning)

	Zones = {
		Default = {
			Eggs = {
				{ ItemTypeId = "Common", Weight = 75, Amount = { Min = 1, Max = 2 } },
				{ ItemTypeId = "Rare", Weight = 20, Amount = { Min = 1, Max = 1 } },
				{ ItemTypeId = "Epic", Weight = 5, Amount = { Min = 1, Max = 1 } },
			},

			-- Temporary testing values (approved 2026-10-29); not final tuning
			Targets = {
				{
					TargetTypeId = "Red",
					Weight = 1,
					Health = { Min = 1, Max = 5 },
					Scale = { Min = 2, Max = 2 },
					RadiusGrowth = { Min = 1.1, Max = 1.3 },
				},
				{ TargetTypeId = "Nothing", Weight = 1 },
			},
		},
	}
}

return ZoneIdData
