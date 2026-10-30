-- Responsibility: Ordinary egg spawning for each player in their own zone. Every player has an independent supply,
-- so nothing scales with population. Owns per-player schedules, per-player caps (checked early; EggService confirms
-- them last), weighted egg type choice, the per-attempt template check, and bounded placement retries.
--
-- Schedules (all numbers in SpawnerConfig; Step runs on the shared server tick):
--   Fresh entry      first opportunity FirstSpawnDelay after entering a zone
--   After each turn  next opportunity interval(n) later, n = the player's live eggs in that zone (ComputeInterval).
--                    A turn whose placement fails still counts, so bad geometry can't spam raycasts
--   At either cap    paused (no timer). When capacity returns, the next wait is interval(n) from then. No backlog
--   Leaving a zone   the unfinished wait is saved for that zone. Re-entering within
--                    SpawnInterval.Max * ReentryCreditMultiplier seconds subtracts the time away: if it ran out,
--                    one opportunity now, then a fresh cycle; otherwise the rest is waited out. Later = fresh entry
--   Outside zones    nothing spawns
--   Death / leaving  ResetPlayer / RemovePlayer drop every schedule and saved wait for that player
-- All of this is runtime-only and never saved.

local ZoneSpawner = {}
ZoneSpawner.__index = ZoneSpawner

-- deps:
--   spawnerConfig      Configs/Zones/SpawnerConfig
--   zoneConfig         Configs/Zones/IdConfig
--   itemCatalog        Shared ItemDefintions
--   fallbackItemTypeId catalog key whose model stands in for a template that vanished after startup
--   templates          { Has: (modelName) -> boolean }
--   zones              ZoneService
--   eggs               EggService
--   eggRegistry        EggRegistry (the same one EggService uses; read for counts only)
--   getPlayers         () -> {Player}   players eligible for eggs (active profile)
--   getRootPosition    (Player) -> Vector3?   nil while dead; a dead player gets no schedule
--   rng                Random-like
--   warn               ((string) -> ())?
function ZoneSpawner.new(deps)
	return setmetatable({
		_config = deps.spawnerConfig,
		_zoneConfig = deps.zoneConfig,
		_items = deps.itemCatalog,
		_fallbackItemTypeId = deps.fallbackItemTypeId,
		_templates = deps.templates,
		_zones = deps.zones,
		_eggs = deps.eggs,
		_eggRegistry = deps.eggRegistry,
		_getPlayers = deps.getPlayers,
		_getRootPosition = deps.getRootPosition,
		_rng = deps.rng,
		_warn = deps.warn or warn,
		_schedules = {}, -- [UserId] = { ZoneId, NextAt: number? }  NextAt nil = paused at a cap
		_saved = {}, -- [UserId] = { [ZoneId] = { Remaining, LeftAt } }  re-entry credit
		_stats = {}, -- [UserId] = { [outcome] = count }; debug only, see TakeStats
	}, ZoneSpawner)
end

-- interval(n) = Max - (Max - Min) * SpawnIntervalCurve ^ max(0, n - BasePickups). See SpawnerConfig
function ZoneSpawner.ComputeInterval(config, count)
	local range = config.SpawnInterval
	local steps = math.max(0, count - config.BasePickups)
	return range.Max - (range.Max - range.Min) * config.SpawnIntervalCurve ^ steps
end

function ZoneSpawner:_count(userId, outcome)
	local byOutcome = self._stats[userId]
	if not byOutcome then
		byOutcome = {}
		self._stats[userId] = byOutcome
	end
	byOutcome[outcome] = (byOutcome[outcome] or 0) + 1
end

-- Outcome counts per owner since the last call, e.g. { [1234] = { Spawned = 3, ["PlacementRejected:Obstructed"] = 12 } }
function ZoneSpawner:TakeStats()
	local stats = self._stats
	self._stats = {}
	return stats
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

-- The profile for a zone: its own IdConfig entry, else the fallback profile, else nil
function ZoneSpawner:GetProfile(zoneId)
	local zones = self._zoneConfig.Zones
	local profile = zones[zoneId]
	if profile then
		return profile
	end
	local fallback = self._zoneConfig.FallbackZoneProfile
	return if fallback then zones[fallback] else nil
end

-- The zone profile's weighted egg list, or nil when the zone spawns no eggs
function ZoneSpawner:GetEggDistribution(zoneId)
	local profile = self:GetProfile(zoneId)
	return profile and profile.Eggs
end

-- Every template exists at startup (ConfigValidator). If one has vanished since, the egg keeps its item and reward
-- and the owner's client shows the fallback model instead. One warning per spawn attempt, never per placement retry.
-- Returns false only when neither the template nor the fallback can be shown
function ZoneSpawner:_checkTemplate(itemTypeId)
	local modelName = self._items[itemTypeId].ModelName
	if self._templates.Has(modelName) then
		return true
	end
	local fallbackId = self._fallbackItemTypeId
	local fallbackModel = self._items[fallbackId].ModelName
	if self._templates.Has(fallbackModel) then
		self._warn(`MODEL OF {modelName} doesnt exist (item {itemTypeId}); spawning it with {fallbackModel} ({fallbackId}) as its visual`)
		return true
	end
	self._warn(`MODEL OF {modelName} doesnt exist (item {itemTypeId}); fallback MODEL OF {fallbackModel} doesnt exist either, skipping this spawn`)
	return false
end

-- One spawn opportunity for `player` in `zoneId`: caps, weighted choice, template check, at most PlacementAttempts candidates
function ZoneSpawner:SpawnFor(player, zoneId)
	local userId = player.UserId
	local distribution = self:GetEggDistribution(zoneId)
	if not distribution then
		self:_count(userId, "NoProfile")
		return nil, "NoProfile"
	end

	-- Checked before placement so a capped player costs no raycasts. EggService checks again right before registering
	local hasCapacity, capReason = self._eggs:HasCapacity(userId, zoneId)
	if not hasCapacity then
		self:_count(userId, capReason)
		return nil, capReason
	end

	local entry = ZoneSpawner.PickWeighted(distribution, self._rng)
	if not self:_checkTemplate(entry.ItemTypeId) then
		self:_count(userId, "ModelMissing")
		return nil, "ModelMissing"
	end

	local amount = self._rng:NextInteger(entry.Amount.Min, entry.Amount.Max)
	for _ = 1, self._config.PlacementAttempts do
		local record, reason, detail = self._eggs:TrySpawn(player, zoneId, entry.ItemTypeId, amount)
		if record then
			self:_count(userId, "Spawned")
			return record
		end
		if reason ~= "PlacementRejected" then
			self:_count(userId, reason)
			return nil, reason
		end
		self:_count(userId, `PlacementRejected:{detail}`)
	end
	-- No valid spot this time; the next opportunity tries again
	self:_count(userId, "PlacementExhausted")
	return nil, "PlacementExhausted"
end

-- Schedules ----------------------------------------------------------------------------------------

function ZoneSpawner:_nextWait(userId, zoneId)
	return ZoneSpawner.ComputeInterval(self._config, self._eggRegistry:CountOwnerZone(userId, zoneId))
end

function ZoneSpawner:_leave(userId, schedule, now)
	local saved = self._saved[userId]
	if not saved then
		saved = {}
		self._saved[userId] = saved
	end
	-- A paused schedule had nothing left to wait for
	local remaining = if schedule.NextAt then math.max(schedule.NextAt - now, 0) else 0
	saved[schedule.ZoneId] = { Remaining = remaining, LeftAt = now }
	self._schedules[userId] = nil
end

function ZoneSpawner:_enter(userId, zoneId, now)
	local saved = self._saved[userId]
	local credit = saved and saved[zoneId]
	if credit then
		saved[zoneId] = nil
		if next(saved) == nil then
			self._saved[userId] = nil
		end
	end

	local nextAt = now + self._config.FirstSpawnDelay
	local window = self._config.SpawnInterval.Max * self._config.ReentryCreditMultiplier
	if credit and now - credit.LeftAt <= window then
		-- Time away counts toward the saved wait; an expired wait means one opportunity right now
		nextAt = now + math.max(credit.Remaining - (now - credit.LeftAt), 0)
	end
	local schedule = { ZoneId = zoneId, NextAt = nextAt }
	self._schedules[userId] = schedule
	return schedule
end

function ZoneSpawner:_stepPlayer(player, now)
	local userId = player.UserId
	local zoneId = if self._getRootPosition(player) then self._zones:GetZoneOf(player) else nil
	local schedule = self._schedules[userId]

	if schedule and schedule.ZoneId ~= zoneId then
		self:_leave(userId, schedule, now)
		schedule = nil
	end
	if not zoneId or not self:GetEggDistribution(zoneId) then
		return
	end
	schedule = schedule or self:_enter(userId, zoneId, now)

	if not self._eggs:HasCapacity(userId, zoneId) then
		schedule.NextAt = nil -- paused; nothing accumulates while capped
		return
	end
	if schedule.NextAt == nil then
		schedule.NextAt = now + self:_nextWait(userId, zoneId) -- capacity came back
		return
	end
	if now < schedule.NextAt then
		return
	end

	self:SpawnFor(player, zoneId)
	-- One opportunity per due time; the next wait reflects the count after this turn
	schedule.NextAt = now + self:_nextWait(userId, zoneId)
end

-- Advances every eligible player's schedule. Non-yielding
function ZoneSpawner:Step(now)
	for _, player in self._getPlayers() do
		self:_stepPlayer(player, now)
	end
end

-- The player's current schedule (debug and tests): { ZoneId, NextAt? } or nil
function ZoneSpawner:GetSchedule(player)
	return self._schedules[player.UserId]
end

-- Death: every schedule and saved wait starts over. Existing eggs stay until collected or expired
function ZoneSpawner:ResetPlayer(player)
	self._schedules[player.UserId] = nil
	self._saved[player.UserId] = nil
end

function ZoneSpawner:RemovePlayer(player)
	self:ResetPlayer(player)
	self._stats[player.UserId] = nil
end

-- A removed zone keeps no schedules or saved waits
function ZoneSpawner:RemoveZone(zoneId)
	for userId, schedule in table.clone(self._schedules) do
		if schedule.ZoneId == zoneId then
			self._schedules[userId] = nil
		end
	end
	for userId, saved in table.clone(self._saved) do
		saved[zoneId] = nil
		if next(saved) == nil then
			self._saved[userId] = nil
		end
	end
end

function ZoneSpawner:Destroy()
	table.clear(self._schedules)
	table.clear(self._saved)
	table.clear(self._stats)
end

return ZoneSpawner
