-- Responsibility: Public starter scheduling, one schedule per zone (eggs are scheduled per player in ZoneSpawner;
-- the two never share counts). Step runs on the shared server tick (SpawnerConfig.TickInterval).
--
--   Activation      only zones with at least one player (ZoneService population). Whether those players are in
--                   runs or on cooldown doesn't matter
--   Fresh entry     first opportunity SpawnerConfig.FirstSpawnDelay after an empty zone becomes occupied
--   Opportunities   one per TickInterval. A roll picks a zone Targets entry; "Nothing" uses the opportunity up
--   Placement       a selected type tries one batch (TargetService.TrySpawnStarter). If every candidate fails, the
--                   type is kept and retried on the next opportunity without rerolling the table
--   At the cap      TargetConfig.StartersPerZone live starters: paused (no timer). When a slot frees, opportunities
--                   resume on the following tick. No backlog
--   Zone empties    the schedule and any kept type are dropped; existing starters live out their lifetime
-- A rolled type whose model is missing uses the opportunity up like Nothing (TargetService warns once).

local TargetSpawner = {}
TargetSpawner.__index = TargetSpawner

TargetSpawner.NOTHING = "Nothing"

-- Heartbeat-accumulated ticks and GetServerTimeNow can disagree by a hair; a tick this close to due counts as due
local DUE_TOLERANCE = 0.01

-- deps:
--   config          Configs/Targets/TargetConfig
--   spawnerConfig   Configs/Zones/SpawnerConfig (TickInterval, FirstSpawnDelay)
--   zoneConfig      Configs/Zones/IdConfig
--   zones           ZoneService
--   targets         TargetService
--   registry        TargetRegistry (read for the starter cap)
--   rng             Random-like
function TargetSpawner.new(deps)
	return setmetatable({
		_config = deps.config,
		_spawnerConfig = deps.spawnerConfig,
		_zoneConfig = deps.zoneConfig,
		_zones = deps.zones,
		_targets = deps.targets,
		_registry = deps.registry,
		_rng = deps.rng,
		_schedules = {}, -- [ZoneId] = { NextAt: number?, Pending: entry? }  NextAt nil = paused at the cap
	}, TargetSpawner)
end

function TargetSpawner.PickWeighted(distribution, rng)
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

-- The zone profile's Targets list (own profile, else the fallback profile), or nil
function TargetSpawner:GetDistribution(zoneId)
	local zones = self._zoneConfig.Zones
	local profile = zones[zoneId]
	if not profile then
		local fallback = self._zoneConfig.FallbackZoneProfile
		profile = if fallback then zones[fallback] else nil
	end
	return profile and profile.Targets
end

function TargetSpawner:_opportunity(zoneId, schedule, distribution, now)
	local entry = schedule.Pending or TargetSpawner.PickWeighted(distribution, self._rng)
	schedule.Pending = nil
	if entry.TargetTypeId == TargetSpawner.NOTHING then
		return
	end
	local record, reason = self._targets:TrySpawnStarter(zoneId, entry, now)
	if not record and reason == "PlacementExhausted" then
		schedule.Pending = entry
	end
end

-- Advances every zone's schedule. Non-yielding
function TargetSpawner:Step(now)
	local tick = self._spawnerConfig.TickInterval
	for _, zone in self._zones:GetZones() do
		local zoneId = zone.ZoneId
		local distribution = self:GetDistribution(zoneId)
		if not distribution or self._zones:GetPopulation(zoneId) == 0 then
			self._schedules[zoneId] = nil
			continue
		end

		local schedule = self._schedules[zoneId]
		if not schedule then
			schedule = { NextAt = now + self._spawnerConfig.FirstSpawnDelay, Pending = nil }
			self._schedules[zoneId] = schedule
		end
		if self._registry:CountStarters(zoneId) >= self._config.StartersPerZone then
			schedule.NextAt = nil -- paused; nothing accumulates while capped
			continue
		end
		if schedule.NextAt == nil then
			schedule.NextAt = now + tick -- a slot freed: resume on the following tick
			continue
		end
		if now < schedule.NextAt - DUE_TOLERANCE then
			continue
		end

		self:_opportunity(zoneId, schedule, distribution, now)
		schedule.NextAt = now + tick
	end

	-- Zones that were unregistered keep nothing
	for zoneId in table.clone(self._schedules) do
		if not self._zones:GetZone(zoneId) then
			self._schedules[zoneId] = nil
		end
	end
end

-- A zone's schedule (debug and tests): { NextAt?, Pending? } or nil
function TargetSpawner:GetSchedule(zoneId)
	return self._schedules[zoneId]
end

function TargetSpawner:RemoveZone(zoneId)
	self._schedules[zoneId] = nil
end

function TargetSpawner:Destroy()
	table.clear(self._schedules)
end

return TargetSpawner
