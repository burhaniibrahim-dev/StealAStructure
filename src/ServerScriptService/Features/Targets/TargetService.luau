-- Responsibility: Target minigame authority. Public starter creation and claims, runs, display acknowledgments,
-- damage, scoring, health/radius progression, placement batches, timeouts, settlement, cooldown, and cleanup.
-- Records live in TargetRegistry; models are server instances made by the world adapter (RobloxTargetWorld), so
-- every player sees them. Clients only decide presentation; nothing they send is trusted beyond a TargetId.
--
-- Clock: every time here is `now` (Runner: workspace:GetServerTimeNow(), never mixed with the eggs' time()).
-- There are no per-entity timers. Every request re-checks its own deadlines, and Sweep (every Heartbeat) settles
-- timeouts, expires starters, finishes exit animations, and runs placement batches. A late request can't touch a
-- newer entity because TargetIds and RunIds are never reused.
--
-- Atomicity: claim, damage, destruction, acknowledgment, timeout, and settlement each run start to finish without
-- yielding (the world adapter's Clone/PivotTo/attribute writes don't yield), so two requests can't interleave.
--
-- Run lifecycle:
--   claim       starter leaves the registry (its zone slot frees immediately), run created in "Waiting";
--               the first scoring target is placed after DisappearDuration (the starter's exit)
--   Waiting     one batch of PlacementCandidates per SpawnerConfig.TickInterval, at most RunPlacementBatches
--   Active      target awaits the owner's acknowledgment (2 * GraceTime), then is revealed to spectators,
--               damageable AppearDuration later, deadline = ack + TargetTime + GraceTime
--   destroyed   score += completion bonus; roll Scale (health) and RadiusGrowth (radius, while growth applies);
--               back to Waiting after DisappearDuration
--   Settled     once, on timeout / acknowledgment timeout / placement exhaustion / missing model / health limit /
--               zone removal. Reward from the highest bracket reached; cooldown only if it was actually paid.
--               Player departure and shutdown discard the run without settlement.

local TargetService = {}
TargetService.__index = TargetService

TargetService.Reason = {
	NotFound = "NotFound",
	InvalidRequest = "InvalidRequest",
	RateLimited = "RateLimited",
	PlayerNotPresent = "PlayerNotPresent",
	ProfileNotActive = "ProfileNotActive",
	NoCharacter = "NoCharacter",
	TooFar = "TooFar",
	ZoneAccess = "ZoneAccess",
	InRun = "InRun",
	OnCooldown = "OnCooldown",
	NotClaimable = "NotClaimable",
	Expired = "Expired",
	NotOwner = "NotOwner",
	NotCurrent = "NotCurrent",
	NotRevealed = "NotRevealed",
	Locked = "Locked",
	InvalidZone = "InvalidZone",
	ZoneCap = "ZoneCap",
	ModelMissing = "ModelMissing",
	PlacementExhausted = "PlacementExhausted",
	-- Successful outcomes
	Claimed = "Claimed",
	Damaged = "Damaged",
	Destroyed = "Destroyed",
}

TargetService.EndReason = {
	Timeout = "Timeout",
	AckTimeout = "AckTimeout",
	PlacementExhausted = "PlacementExhausted",
	ModelMissing = "ModelMissing",
	HealthLimit = "HealthLimit",
	ZoneRemoved = "ZoneRemoved",
}

local Reason = TargetService.Reason
local EndReason = TargetService.EndReason

local STARTER, SCORING = "Starter", "Scoring"
local MAX_EXACT_HEALTH = 2 ^ 53 -- beyond this, doubles can't hold every whole health value

local function isPositiveFinite(value)
	return type(value) == "number" and value == value and value > 0 and value ~= math.huge
end

local function isTargetId(value)
	return isPositiveFinite(value) and math.floor(value) == value
end

-- Seconds of scoring time left: clamp(deadline - now, 0, TargetTime). The hidden grace keeps it at TargetTime
-- for the first GraceTime seconds after acknowledgment
function TargetService.TimeRemaining(deadline, now, targetTime)
	return math.clamp(deadline - now, 0, targetTime)
end

-- Extra points for destroying a target: (health removed / 2) * time remaining. Base points are added per hit
function TargetService.CompletionBonus(removed, timeRemaining)
	return removed / 2 * timeRemaining
end

-- deps:
--   config          Configs/Targets/TargetConfig
--   batchInterval   SpawnerConfig.TickInterval (wait between a run's placement batches; request rate window)
--   registry        TargetRegistry
--   placement       TargetPlacement
--   world           { HasModel(modelName), Create(record, modelName) -> model, SetAttributes(model, attrs), Destroy(model) }
--   rewards         TargetRewards
--   zones           ZoneService
--   data            PlayerDataService contract (IsActive)
--   isPlayerPresent (Player) -> boolean
--   getRootPosition (Player) -> Vector3?   non-yielding; nil without a living character
--   now             () -> number
--   rng             Random-like
--   Signal
--   warn            ((string) -> ())?
function TargetService.new(deps)
	return setmetatable({
		_deps = deps,
		_config = deps.config,
		_registry = deps.registry,
		_world = deps.world,
		_rng = deps.rng,
		_warn = deps.warn or warn,
		_cooldownUntil = {}, -- [UserId] = time; runtime only, survives rejoining this server
		_requestWindows = {}, -- [Player] = { Start, Count }
		_leaving = {}, -- { { Model, EndsAt } } exit animations of entities no longer in the registry
		_warnedMissing = {}, -- [TargetTypeId] = true
		_destroyed = false,

		StatusChanged = deps.Signal.new(), -- (player) run started/ended or cooldown changed
		Settled = deps.Signal.new(), -- (run, endReason, paidDrop?)
	}, TargetService)
end

-- Types and models -----------------------------------------------------------------

-- A type is enabled while its configured model exists. Checked live, so a model removed at runtime disables
-- the type (one warning) and one restored re-enables it
function TargetService:IsTypeEnabled(targetTypeId)
	local definition = self._config.Types[targetTypeId]
	if not definition then
		return false
	end
	if self._world:HasModel(definition.ModelName) then
		self._warnedMissing[targetTypeId] = nil
		return true
	end
	if not self._warnedMissing[targetTypeId] then
		self._warnedMissing[targetTypeId] = true
		self._warn(`MODEL OF {definition.ModelName} doesnt exist; target type {targetTypeId} is disabled until it does`)
	end
	return false
end

function TargetService:_createModel(record)
	record.Model = self._world:Create(record, self._config.Types[record.TargetTypeId].ModelName)
end

-- The record has already left the registry (so this runs once per record); its model plays the exit animation,
-- then Sweep destroys it
function TargetService:_leave(record, now)
	local model = record.Model
	if model then
		self._world:SetAttributes(model, { State = "Leaving" })
		table.insert(self._leaving, { Model = model, EndsAt = now + self._config.DisappearDuration })
	end
end

-- The record has already left the registry; its model goes at once (departure, zone removal, shutdown)
function TargetService:_destroyModel(record)
	if record.Model then
		self._world:Destroy(record.Model)
	end
end

-- Player checks ------------------------------------------------------------------

-- Drops requests over HitRequestsPerTick per batchInterval window (hits and acknowledgments together)
function TargetService:_admit(player, now)
	local window = self._requestWindows[player]
	if not window or now - window.Start >= self._deps.batchInterval then
		window = { Start = now, Count = 0 }
		self._requestWindows[player] = window
	end
	if window.Count >= self._config.HitRequestsPerTick then
		return false
	end
	window.Count += 1
	return true
end

function TargetService:_checkPlayer(player, position)
	local deps = self._deps
	if not deps.isPlayerPresent(player) then
		return false, Reason.PlayerNotPresent
	end
	if not deps.data:IsActive(player) then
		return false, Reason.ProfileNotActive
	end
	local root = deps.getRootPosition(player)
	if not root then
		return false, Reason.NoCharacter
	end
	if (root - position).Magnitude > self._config.HitRange then
		return false, Reason.TooFar
	end
	return true
end

function TargetService:IsOnCooldown(userId, now)
	local untilTime = self._cooldownUntil[userId]
	if untilTime and now >= untilTime then
		self._cooldownUntil[userId] = nil
		return false
	end
	return untilTime ~= nil
end

-- What this player's client needs to present starters: { InRun, CooldownEndsAt } (0 = no cooldown)
function TargetService:GetStatus(player)
	return {
		InRun = self._registry:GetRunOf(player.UserId) ~= nil,
		CooldownEndsAt = self._cooldownUntil[player.UserId] or 0,
	}
end

-- Public starters -------------------------------------------------------------------

-- One public opportunity in `zoneId` for the zone's Targets entry: at most PlacementCandidates candidates.
-- Returns the starter record, or nil and a Reason (TargetSpawner keeps the entry only on PlacementExhausted)
function TargetService:TrySpawnStarter(zoneId, entry, now)
	if self._destroyed then
		return nil, Reason.InvalidZone
	end
	local zone = self._deps.zones:GetZone(zoneId)
	if not zone then
		return nil, Reason.InvalidZone
	end
	if self._registry:CountStarters(zoneId) >= self._config.StartersPerZone then
		return nil, Reason.ZoneCap
	end
	if not self:IsTypeEnabled(entry.TargetTypeId) then
		return nil, Reason.ModelMissing
	end

	local lastReason = nil
	for _ = 1, self._config.PlacementCandidates do
		local position, reason = self._deps.placement:TryStarter(zone, self._rng)
		if position then
			local claimableAt = now + self._config.AppearDuration
			local record = self._registry:CreateStarter({
				TargetTypeId = entry.TargetTypeId,
				ZoneId = zoneId,
				Position = position,
				Settings = table.clone(entry), -- the zone's run tuning, locked in at claim
				CreatedAt = now,
				ClaimableAt = claimableAt,
				ExpiresAt = claimableAt + self._config.StarterLifetime,
			})
			self:_createModel(record)
			return record
		end
		lastReason = reason
	end
	return nil, Reason.PlacementExhausted, lastReason
end

-- Hits ---------------------------------------------------------------------------------

-- Network entry point for the temporary click interaction: rate limit, shape check, then ApplyHit with
-- TargetConfig.TestHitDamage. Consumes nothing
function TargetService:HandleHitRequest(player, targetId)
	if not self:_admit(player, self._deps.now()) then
		return false, Reason.RateLimited
	end
	if not isTargetId(targetId) then
		return false, Reason.InvalidRequest
	end
	return self:ApplyHit(player, targetId, self._config.TestHitDamage)
end

-- The authoritative hit API (real throwing will call this with its own server-computed damage).
-- A hit on a starter is a claim; a hit on a scoring target is damage. Returns true, outcome or false, reason
function TargetService:ApplyHit(player, targetId, damage)
	if self._destroyed then
		return false, Reason.NotFound
	end
	if not isPositiveFinite(damage) then
		return false, Reason.InvalidRequest
	end
	local record = self._registry:Get(targetId)
	if not record then
		return false, Reason.NotFound
	end
	local now = self._deps.now()
	if record.Kind == STARTER then
		return self:_claim(player, record, now)
	end
	return self:_damage(player, record, damage, now)
end

function TargetService:_claim(player, starter, now)
	if now < starter.ClaimableAt then
		return false, Reason.NotClaimable
	end
	if now >= starter.ExpiresAt then
		return false, Reason.Expired
	end
	local userId = player.UserId
	if self._registry:GetRunOf(userId) then
		return false, Reason.InRun
	end
	if self:IsOnCooldown(userId, now) then
		return false, Reason.OnCooldown
	end
	local ok, reason = self:_checkPlayer(player, starter.Position)
	if not ok then
		return false, reason
	end
	if not self._deps.zones:CanAccess(player, starter.ZoneId) then
		return false, Reason.ZoneAccess
	end

	-- Commit. No yields from here to the end of the function
	self._registry:Remove(starter.TargetId)
	self:_leave(starter, now)
	local settings = starter.Settings
	self._registry:CreateRun({
		OwnerUserId = userId,
		Player = player,
		TargetTypeId = starter.TargetTypeId,
		ZoneId = starter.ZoneId,
		Settings = settings,
		Origin = starter.Position,
		State = "Waiting",
		Score = 0, -- the claiming hit scores nothing
		SpawnIndex = 0,
		Radius = self._config.InitialRadius,
		MaxHealth = self._rng:NextInteger(settings.Health.Min, settings.Health.Max),
		BatchesLeft = self._config.RunPlacementBatches,
		NextAt = now + self._config.DisappearDuration,
		TargetId = nil,
	})
	self.StatusChanged:Fire(player)
	return true, Reason.Claimed
end

function TargetService:_damage(player, target, damage, now)
	if target.OwnerUserId ~= player.UserId then
		return false, Reason.NotOwner
	end
	local run = self._registry:GetRun(target.RunId)
	if not run or run.State ~= "Active" or run.TargetId ~= target.TargetId then
		return false, Reason.NotCurrent
	end
	if target.State ~= "Live" then
		return false, Reason.NotRevealed
	end
	if now < target.DamageUnlockAt then
		return false, Reason.Locked
	end
	if now >= target.Deadline then
		-- A late or skipped sweep must not leave a hittable target behind
		self:_settle(run, EndReason.Timeout, now)
		return false, Reason.Expired
	end
	local ok, reason = self:_checkPlayer(player, target.Position)
	if not ok then
		return false, reason
	end

	-- Commit. Only health actually removed scores, never overkill
	local removed = math.min(damage, target.Health)
	target.Health -= removed
	target.Removed += removed
	run.Score += removed
	if target.Health > 0 then
		self._world:SetAttributes(target.Model, { Health = target.Health })
		return true, Reason.Damaged
	end

	local remaining = TargetService.TimeRemaining(target.Deadline, now, self._config.TargetTime)
	run.Score += TargetService.CompletionBonus(target.Removed, remaining)
	self:_advance(run, target, now)
	return true, Reason.Destroyed
end

-- After a destruction: rolls the next health and radius, then waits for the exit animation before placing
function TargetService:_advance(run, target, now)
	self._registry:Remove(target.TargetId)
	self:_leave(target, now)
	run.TargetId = nil

	local settings = run.Settings
	local nextHealth = target.MaxHealth * self._rng:NextInteger(settings.Scale.Min, settings.Scale.Max)
	-- Growth applies after destroying targets 1 .. limit-1, so spawns 2..limit grow and later ones keep the radius
	if run.SpawnIndex < self._config.RadiusGrowthSpawnLimit then
		run.Radius *= self._rng:NextNumber(settings.RadiusGrowth.Min, settings.RadiusGrowth.Max)
	end
	if nextHealth ~= nextHealth or nextHealth > MAX_EXACT_HEALTH then
		self._warn(`[Targets] run {run.RunId}: next health {nextHealth} is beyond exact whole numbers; ending the run`)
		self:_settle(run, EndReason.HealthLimit, now)
		return
	end
	run.MaxHealth = nextHealth
	run.State = "Waiting"
	run.BatchesLeft = self._config.RunPlacementBatches
	run.NextAt = now + self._config.DisappearDuration
end

-- Display acknowledgment ---------------------------------------------------------------

-- The owner's client started showing the target. Starts its timer and reveals it to spectators.
-- Duplicate, late, or stale acknowledgments are ignored. Returns true or false, reason
function TargetService:HandleShown(player, targetId)
	local now = self._deps.now()
	if not self:_admit(player, now) then
		return false, Reason.RateLimited
	end
	if not isTargetId(targetId) then
		return false, Reason.InvalidRequest
	end
	local target = self._registry:Get(targetId)
	if not target or target.Kind ~= SCORING then
		return false, Reason.NotFound
	end
	if target.OwnerUserId ~= player.UserId then
		return false, Reason.NotOwner
	end
	if target.State ~= "AwaitingAck" then
		return false, Reason.NotCurrent
	end
	local run = self._registry:GetRun(target.RunId)
	if not run or run.State ~= "Active" or run.TargetId ~= targetId then
		return false, Reason.NotCurrent
	end
	if now > target.AckDeadline then
		return false, Reason.Expired -- Sweep settles the run
	end

	local config = self._config
	target.State = "Live"
	target.AckAt = now
	target.DamageUnlockAt = now + config.AppearDuration
	target.Deadline = now + config.TargetTime + config.GraceTime
	self._world:SetAttributes(target.Model, { Revealed = true, Deadline = target.Deadline })
	return true
end

-- Placement batches ------------------------------------------------------------------

function TargetService:_placeBatch(run, now)
	local zone = self._deps.zones:GetZone(run.ZoneId)
	if not zone then
		self:_settle(run, EndReason.ZoneRemoved, now)
		return
	end
	if not self:IsTypeEnabled(run.TargetTypeId) then
		self:_settle(run, EndReason.ModelMissing, now)
		return
	end

	local config = self._config
	for _ = 1, config.PlacementCandidates do
		local position = self._deps.placement:TryRun(zone, run.Origin, run.Radius, run.OwnerUserId, self._rng)
		if position then
			run.SpawnIndex += 1
			local target = self._registry:CreateScoring({
				RunId = run.RunId,
				OwnerUserId = run.OwnerUserId,
				TargetTypeId = run.TargetTypeId,
				ZoneId = run.ZoneId,
				Position = position,
				CreatedAt = now,
				MaxHealth = run.MaxHealth,
				Health = run.MaxHealth,
				Removed = 0,
				State = "AwaitingAck",
				AckDeadline = now + 2 * config.GraceTime,
			})
			self:_createModel(target)
			run.State = "Active"
			run.TargetId = target.TargetId
			run.NextAt = nil
			return
		end
	end

	-- Failed batches never advance health or radius
	run.BatchesLeft -= 1
	if run.BatchesLeft <= 0 then
		self:_settle(run, EndReason.PlacementExhausted, now)
	else
		run.NextAt = now + self._deps.batchInterval
	end
end

-- Sweep -----------------------------------------------------------------------------

-- Runs every Heartbeat. Non-yielding
function TargetService:Sweep(now)
	for index = #self._leaving, 1, -1 do
		local entry = self._leaving[index]
		if now >= entry.EndsAt then
			table.remove(self._leaving, index)
			self._world:Destroy(entry.Model)
		end
	end

	for _, record in self._registry:GetTargets() do
		if record.Kind == STARTER then
			if now >= record.ExpiresAt and self._registry:Remove(record.TargetId) then
				self:_leave(record, now)
			end
		else
			local run = self._registry:GetRun(record.RunId)
			if record.State == "AwaitingAck" and now > record.AckDeadline then
				self:_settle(run, EndReason.AckTimeout, now)
			elseif record.State == "Live" and now >= record.Deadline then
				self:_settle(run, EndReason.Timeout, now)
			end
		end
	end

	for _, run in self._registry:GetRuns() do
		if run.State == "Waiting" and run.NextAt and now >= run.NextAt then
			self:_placeBatch(run, now)
		end
	end
end

-- Settlement --------------------------------------------------------------------------

-- The single end of a run the player is still here for. Returns false if it already settled
function TargetService:_settle(run, endReason, now)
	if not run or run.State == "Settled" then
		return false
	end
	run.State = "Settled"
	local target = run.TargetId and self._registry:Remove(run.TargetId)
	run.TargetId = nil
	if target then
		self:_leave(target, now)
	end
	self._registry:RemoveRun(run.RunId)

	local paid = nil
	local drop = self._deps.rewards:Resolve(run.Score)
	if drop then
		local ok, why = self._deps.rewards:Pay(run.Player, drop)
		if ok then
			paid = drop
			self._cooldownUntil[run.OwnerUserId] = now + self._config.RewardCooldown
		else
			self._warn(`[Targets] run {run.RunId} (score {run.Score}) earned a reward that was not paid ({why}); no cooldown`)
		end
	end
	self.Settled:Fire(run, endReason, paid)
	self.StatusChanged:Fire(run.Player)
	return true
end

-- Ends a run with no settlement and removes its target at once (departure, shutdown)
function TargetService:_discard(run)
	run.State = "Settled"
	local target = run.TargetId and self._registry:Remove(run.TargetId)
	run.TargetId = nil
	if target then
		self:_destroyModel(target)
	end
	self._registry:RemoveRun(run.RunId)
end

-- Cleanup ---------------------------------------------------------------------------

-- Idempotent: Runner calls it on Releasing and again on PlayerRemoving. No reward for a player who left.
-- The cooldown stays (keyed by UserId) so rejoining this server doesn't clear it
function TargetService:RemovePlayer(player)
	local run = self._registry:GetRunOf(player.UserId)
	if run then
		self:_discard(run)
	end
	self._requestWindows[player] = nil
end

-- The zone's starters vanish; runs that started there settle what they earned
function TargetService:RemoveZone(zoneId)
	local now = self._deps.now()
	for _, record in self._registry:GetTargets() do
		if record.Kind == STARTER and record.ZoneId == zoneId and self._registry:Remove(record.TargetId) then
			self:_destroyModel(record)
		end
	end
	for _, run in self._registry:GetRuns() do
		if run.ZoneId == zoneId then
			self:_settle(run, EndReason.ZoneRemoved, now)
		end
	end
end

function TargetService:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, run in self._registry:GetRuns() do
		self:_discard(run)
	end
	for _, record in self._registry:GetTargets() do
		self._registry:Remove(record.TargetId)
		self:_destroyModel(record)
	end
	for _, entry in self._leaving do
		self._world:Destroy(entry.Model)
	end
	table.clear(self._leaving)
	self.StatusChanged:DisconnectAll()
	self.Settled:DisconnectAll()
end

return TargetService
