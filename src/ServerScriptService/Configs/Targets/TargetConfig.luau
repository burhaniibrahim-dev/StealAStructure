-- Responsibility: Server-only target minigame rules (TargetSpawner, TargetService, TargetPlacement).
-- Per-zone weights and run tuning (Health, Scale, RadiusGrowth) live in Configs/Zones/IdConfig under Targets.
-- Public scheduling reuses SpawnerConfig.TickInterval and SpawnerConfig.FirstSpawnDelay.
-- The display acknowledgment timeout is not configured separately: it is always 2 * GraceTime.
-- Times are seconds, distances are studs. ConfigValidator checks every value at startup.

return {
	-- Public starters --------------------------------------------------------
	StartersPerZone = 3, -- unclaimed starters a zone may hold; active-run targets don't count
	StarterLifetime = 5, -- starts once the appear animation has finished (AppearDuration)

	-- Scoring targets --------------------------------------------------------
	TargetTime = 5, -- displayed/scoring time per target
	GraceTime = 0.5, -- hidden extra allowance: deadline = acknowledgment + TargetTime + GraceTime

	-- Presentation timing (also sent to clients as attributes on Workspace.Targets)
	AppearDuration = 0.1, -- starters can't be claimed and targets can't be damaged during it
	DisappearDuration = 0.1, -- a claimed/destroyed entity's exit; the next scoring target is placed after it

	-- Placement ---------------------------------------------------------------
	PlacementCandidates = 60, -- per batch; a public opportunity is one batch
	RunPlacementBatches = 5, -- a run gives up after this many failed batches (one per SpawnerConfig.TickInterval)
	InitialRadius = 5, -- scoring target #1, around the claimed starter's position (horizontal)
	RadiusGrowthSpawnLimit = 10, -- the radius grows after destroying targets #1..#(limit - 1); #limit onward keep it
	Clearance = 4, -- minimum 3D distance between targets (starters and scoring targets)
	EggClearance = 6, -- minimum 3D distance between eggs and targets, both ways: targets avoid eggs, eggs avoid targets
	SurfaceOffset = 0, -- target pivot (authored at the model's base) above the ground hit; 0 = flush

	-- Rewards (design pending) -------------------------------------------------
	RewardCooldown = 30, -- provisional; starts only when a reward is actually paid, blocks every target type
	-- Highest bracket reached gives one weighted drop: { { MinScore = n, Drops = { { Weight = w, ... } } } }
	-- Empty until rewards are designed: runs settle with no reward and no cooldown
	RewardBrackets = {},

	-- Temporary click interaction (replaced by real throwing) ------------------
	TestHitDamage = 1, -- damage per accepted click; consumes nothing
	HitRequestsPerTick = 10, -- per player per SpawnerConfig.TickInterval, hits and acknowledgments together
	HitRange = 150, -- max server-measured HumanoidRootPart distance to the target

	-- Target types ------------------------------------------------------------
	-- Model: ReplicatedStorage.Assets.Targetables.Targets.<ModelName>, a Model with its pivot at its base.
	-- A missing model disables that type with a warning; it never stops the server
	Types = {
		Red = { ModelName = "Target" },
	},
}
