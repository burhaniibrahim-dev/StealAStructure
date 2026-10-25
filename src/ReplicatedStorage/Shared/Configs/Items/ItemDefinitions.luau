-- Responsibility: Client-safe egg presentation data and the shared stack rule.
-- Spawn rules (weights, amounts, timing) are server-only: see ServerScriptService/Configs/PickupConfig.
--
-- Adding an egg type: add an entry here, then reference its key from PickupConfig.Zones.
-- Keys are the ItemTypeId used by inventories, so never rename one after release.

return {
	-- Maximum count per egg type. Each egg type is its own stack
	MAX_STACK = 100,

	-- Optional collect sound; leave empty to play nothing
	COLLECT_SOUND_ID = "",

	Items = {
		SnowEgg = {
			DisplayName = "Snow Egg",
			Color = Color3.fromRGB(235, 244, 255),
			Icon = "", -- rbxassetid; empty falls back to a colour swatch
			ModelName = "SnowEgg", -- ReplicatedStorage.Assets.Pickups.<ModelName>; generated egg if missing
			Order = 1,
		},
		IceEgg = {
			DisplayName = "Ice Egg",
			Color = Color3.fromRGB(120, 200, 255),
			Icon = "",
			ModelName = "IceEgg",
			Order = 2,
		},
		AuroraEgg = {
			DisplayName = "Aurora Egg",
			Color = Color3.fromRGB(150, 255, 190),
			Icon = "",
			ModelName = "AuroraEgg",
			Order = 3,
		},
	},
}
