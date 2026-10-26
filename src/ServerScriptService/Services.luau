-- Responsibility: Shared handles to the live server services, filled once by Runner at startup.
-- Other features (tutorial, throwing, traps) read these at use time, not at require time:
--   local Services = require(ServerScriptService.Services)
--   Services.Inventory:TryConsume(player, "SnowEgg", 1)

return {
	PlayerData = nil,
	Inventory = nil,
	Zones = nil,
	Eggs = nil,
}
