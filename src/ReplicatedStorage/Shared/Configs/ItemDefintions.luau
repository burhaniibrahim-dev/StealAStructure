-- Responsibility: Client-safe egg catalog, keyed by ItemTypeId. Every top-level key is an egg type.
-- Inventory rules live in Shared/Configs/InventoryConfig; spawn rules are server-only (ServerScriptService/Configs).
--
-- Adding an egg type: add an entry here, put a Model or BasePart named <ModelName> in
-- ReplicatedStorage.Assets.Eggs.PickUps (the server refuses to start if it's missing), then reference
-- its key from Configs/Zones/IdConfig. Keys are the ItemTypeId used by inventories, so never rename one after release.
--
-- VisualFallback: exactly one egg sets this. If another egg's template disappears after startup, that egg is shown
-- with this egg's model (same item, same reward). Its own template must exist at startup.

return {
	SnowEgg = {
		DisplayName = "Snow Egg",
		Color = Color3.fromRGB(235, 244, 255),
		Icon = "", -- rbxassetid; empty falls back to a colour swatch
		ModelName = "SnowEgg", -- ReplicatedStorage.Assets.Eggs.PickUps.<ModelName>
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

	Common = {
		DisplayName = "Common",
		Color = Color3.fromRGB(235, 244, 255),
		Icon = "", -- rbxassetid; empty falls back to a colour swatch
		ModelName = "Common", -- ReplicatedStorage.Assets.Eggs.PickUps.<ModelName>
		Order = 1,
		VisualFallback = true,
	},
	Rare = {
		DisplayName = "Rare",
		Color = Color3.fromRGB(120, 200, 255),
		Icon = "",
		ModelName = "Rare",
		Order = 2,
	},
	Epic = {
		DisplayName = "Epic",
		Color = Color3.fromRGB(150, 255, 190),
		Icon = "",
		ModelName = "Epic",
		Order = 3,
	},
}
