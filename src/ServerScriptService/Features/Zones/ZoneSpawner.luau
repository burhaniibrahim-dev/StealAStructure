-- Responsibility: Ordinary floor spawn scheduling. One timer per zone, driven by that zone's population.
-- Supply scales with players in a zone up to a cap, rather than one loop per player, so a crowd can't
-- create unlimited shared supply. Owns per-zone budgets, weighted egg type choice, and bounded placement retries.
--
-- Budget(zone, population)   = min(MaxPickups, BasePickups + PickupsPerExtraPlayer * (min(pop, PopulationCap) - 1))
-- Interval(zone, population) = random(SpawnInterval) / min(1 + RatePerExtraPlayer * (min(pop, cap) - 1), MaxRateMultiplier)
-- Empty zones have no timer. The first player entering waits one interval, so zone-hopping can't burst spawns.

local ZoneSpawner = {}
ZoneSpawner.__index = ZoneSpawner

-- deps: config (PickupConfig), zones (ZoneService), eggs (EggService), eggRegistry (same as EggService), rng
function ZoneSpawner.new(deps)
	return setmetatable({
		_config = deps.config,
		_zones = deps.zones,
		_eggs = deps.eggs,
		_eggRegistry = deps.eggRegistry,
		_rng = deps.rng,
		_nextSpawnAt = {}, -- [ZoneId] = time
		_stats = {}, -- [ZoneId] = { [outcome] = count }; debug only, see TakeStats
	}, ZoneSpawner)
end

function ZoneSpawner:_count(zoneId, outcome)
	local byOutcome = self._stats[zoneId]
	if not byOutcome then
		byOutcome = {}
		self._stats[zoneId] = byOutcome
	end
	byOutcome[outcome] = (byOutcome[outcome] or 0) + 1
end

-- Outcome counts since the last call, e.g. { Meadow = { Spawned = 3, ["PlacementRejected:Obstructed"] = 12 } }
function ZoneSpawner:TakeStats()
	local stats = self._stats
	self._stats = {}
	return stats
end

function ZoneSpawner.ComputeBudget(profile, population, schedule)
	if population <= 0 then
		return 0
	end
	local effective = math.min(population, schedule.PopulationCap)
	local budget = profile.BasePickups + profile.PickupsPerExtraPlayer * (effective - 1)
	return math.min(math.floor(budget), profile.MaxPickups)
end

function ZoneSpawner.ComputeInterval(schedule, population, rng)
	local effective = math.clamp(population, 1, schedule.PopulationCap)
	local multiplier = math.min(1 + schedule.RatePerExtraPlayer * (effective - 1), schedule.MaxRateMultiplier)
	return rng:NextNumber(schedule.SpawnInterval.Min, schedule.SpawnInterval.Max) / multiplier
end

-- Weights are validated > 0 at startup
function ZoneSpawner.PickWeighted(distribution, rng)
	local total = 0
	for _, entry in distribution do
		total += entry.Weight
	end
	local roll = rng:NextNumber(0, total)
	for _, entry in distribution do
		roll -= entry.Weight
		if roll < 0 then
			return entry
		end
	end
	return distribution[#distribution] -- roll landed exactly on total
end

function ZoneSpawner:GetProfile(zoneId)
	local zones = self._config.Zones
	local profile = zones[zoneId]
	if profile then
		return profile
	end
	local fallback = self._config.FallbackZoneProfile
	return if fallback then zones[fallback] else nil
end

-- One spawn opportunity for a zone: budget check, weighted choice, at most MaxAttempts candidates
function ZoneSpawner:SpawnInZone(zoneId)
	local profile = self:GetProfile(zoneId)
	if not profile then
		self:_count(zoneId, "NoProfile")
		return nil, "NoProfile"
	end
	local budget = ZoneSpawner.ComputeBudget(profile, self._zones:GetPopulation(zoneId), self._config.Schedule)
	if self._eggRegistry:CountZone(zoneId) >= budget then
		self:_count(zoneId, "ZoneBudget")
		return nil, "ZoneBudget"
	end
	if self._eggRegistry:CountOrdinary() >= self._config.ServerMaxPickups then
		self:_count(zoneId, "ServerBudget")
		return nil, "ServerBudget"
	end

	local entry = ZoneSpawner.PickWeighted(profile.Distribution, self._rng)
	local amount = self._rng:NextInteger(entry.Amount.Min, entry.Amount.Max)
	for _ = 1, self._config.Placement.MaxAttempts do
		local record, reason, detail = self._eggs:TrySpawnOrdinary(zoneId, entry.ItemTypeId, amount, budget)
		if record then
			self:_count(zoneId, "Spawned")
			return record
		end
		if reason ~= "PlacementRejected" then
			self:_count(zoneId, reason)
			return nil, reason
		end
		self:_count(zoneId, `PlacementRejected:{detail}`)
	end
	-- No valid spot this time; the next scheduled opportunity tries again
	self:_count(zoneId, "PlacementExhausted")
	return nil, "PlacementExhausted"
end

function ZoneSpawner:Step(now)
	for _, zone in self._zones:GetZones() do
		local zoneId = zone.ZoneId
		local population = self._zones:GetPopulation(zoneId)
		if population <= 0 or self:GetProfile(zoneId) == nil then
			self._nextSpawnAt[zoneId] = 	nil
			continue
		end

		local nextAt = self._nextSpawnAt[zoneId]
		if nextAt == nil then
			self._nextSpawnAt[zoneId] = now + ZoneSpawner.ComputeInterval(self._config.Schedule, population, self._rng)
			continue
		end
		if now < nextAt then
			continue
		end

		self._nextSpawnAt[zoneId] = now + ZoneSpawner.ComputeInterval(self._config.Schedule, population, self._rng)
		self:SpawnInZone(zoneId)
	end
end

-- Called when a zone is removed so its timer can't fire for a zone that no longer exists
function ZoneSpawner:RemoveZone(zoneId)
	self._nextSpawnAt[zoneId] = nil
end

function ZoneSpawner:GetNextSpawnAt(zoneId)
	return self._nextSpawnAt[zoneId]
end

function ZoneSpawner:Destroy()
	table.clear(self._nextSpawnAt)
end

return ZoneSpawner
