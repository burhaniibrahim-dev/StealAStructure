-- Responsibility: Server-only, authoritative floor egg lifecycle and collection rules. Clients never receive this file.
-- ConfigValidator checks every value at startup. Times are seconds, distances are studs.

return {
	-- Lifetime -------------------------------------------------------------
	PickupLifetime = 30, -- ordinary floor eggs despawn after this long

	-- Collection -----------------------------------------------------------
	PickupRadius = 3, -- client trigger range, sent in EggSnapshot. The client requests collection on entering it
	CollectRadius = 8, -- max server-measured HumanoidRootPart distance; tolerance for replication lag
	CollectRequestsPerTick = 20, -- per player, per SpawnerConfig.TickInterval; extra requests are dropped
	InventoryFullCooldown = 1, -- per player, per egg type
}
