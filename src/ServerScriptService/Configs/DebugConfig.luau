-- Responsibility: Central switch for server debug output. Runner is the only consumer.
return {
	-- Prints each player's zone, egg counts, and spawn outcomes to Output every N seconds. Set false before release
	DebugSpawnLog = true,
	DebugLogInterval = 5,
}
