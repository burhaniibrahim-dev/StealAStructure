-- Responsibility: Per-player egg scheduling (ZoneSpawner). Every player has an independent egg supply, so nothing
-- here scales with population. Times are seconds.
local Schedule = {
	TickInterval = 0.25, -- shared server tick for spawning and expiry; also the collection rate-limit window
	PlacementAttempts = 8, -- placement candidates per spawn opportunity; then skip until the next one

	-- Timing. The wait before a player's next egg in a zone, given n = their live eggs in that zone:
	--   interval(n) = SpawnInterval.Max - (SpawnInterval.Max - SpawnInterval.Min) * SpawnIntervalCurve ^ max(0, n - BasePickups)
	-- Below BasePickups every wait is SpawnInterval.Min (quick refill); above it the wait climbs toward Max.
	SpawnInterval = { Min = 1, Max = 5 }, -- bounds of the wait between a player's spawns
	SpawnIntervalCurve = 0.9, -- 0 < r <= 1. Closer to 1 = the wait climbs more slowly, so zones stay fuller
	FirstSpawnDelay = 0.5, -- wait before the first egg when a player enters a zone fresh
	ReentryCreditMultiplier = 5, -- a zone's unfinished wait is kept for SpawnInterval.Max * this after leaving it

	BasePickups = 4, -- soft target per player per zone: the spawner replenishes toward it
	MaxPickups = 16, -- hard cap per player per zone
	MaxPickupsPerPlayer = 150, -- hard cap per player across all zones (bounds what one client renders)
}

return Schedule
