-- Responsibility: Egg distribution per ZoneId. Each profile is a weighted list read directly by ZoneSpawner.
-- ItemTypeIds must exist in Shared/Configs/ItemDefintions; Amount must fit InventoryConfig.MAX_STACK.
local ZoneIdData = {
	FallbackZoneProfile = "Default",-- Zones whose ZoneId has no entry in Zones use this profile (false = no spawning)

	Zones = {
		Default = {
    		------------------------Zone distributions-----------------------
			{ ItemTypeId = "Common", Weight = 75, Amount = { Min = 1, Max = 2 } },
			{ ItemTypeId = "Rare", Weight = 20, Amount = { Min = 1, Max = 1 } },
			{ ItemTypeId = "Epic", Weight = 5, Amount = { Min = 1, Max = 1 } },
		},
	}
}

return ZoneIdData
