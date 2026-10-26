local TestKit = require("../TestKit")
local describe, it, eq, truthy, falsy = TestKit.describe, TestKit.it, TestKit.eq, TestKit.truthy, TestKit.falsy

local ZoneSpawner = TestKit.ZoneSpawner

describe("Placement", function()
	it("stops after MaxAttempts when geometry is invalid", function()
		local sys = TestKit.System()
		sys.addZone("Lake")
		sys.world.material = "Water"
		local record, reason = sys.spawner:SpawnInZone("Lake")
		eq(record, nil, "spawned")
		eq(reason, "ZoneBudget", "an empty zone has no budget")

		sys.addPlayer("A", Vector3.new(-19, 3, -19))
		sys.zones:Poll()
		sys.world.raycasts = 0
		record, reason = sys.spawner:SpawnInZone("Lake")
		eq(record, nil, "spawned on water")
		eq(reason, "PlacementExhausted", "reason")
		eq(sys.world.raycasts, sys.config.Placement.MaxAttempts, "bounded attempts")
		eq(sys.eggRegistry:Count(), 0, "nothing registered")

		-- Next opportunity tries again and succeeds once the ground is valid
		sys.world.material = "Snow"
		truthy(sys.spawner:SpawnInZone("Lake"), "later spawn")
	end)

	it("rejects steep slopes, blocked surfaces, no ground, embedded rays, and obstructions", function()
		local sys = TestKit.System()
		local _, zone = sys.addZone("Meadow")
		local rng = TestKit.FakeRandom()

		sys.world.normal = Vector3.new(1, 1, 0).Unit -- 45 degrees
		local _, reason = sys.placement:TryCandidate(zone, rng)
		eq(reason, "TooSteep", "slope")
		sys.world.normal = Vector3.new(0, 1, 0)

		sys.world.blocked = true
		_, reason = sys.placement:TryCandidate(zone, rng)
		eq(reason, "BlockedSurface", "blocked")
		sys.world.blocked = false

		sys.world.noGround = true
		_, reason = sys.placement:TryCandidate(zone, rng)
		eq(reason, "NoGround", "no ground")
		sys.world.noGround = false

		_, reason = sys.placement:Validate(Vector3.new(0, 0.01, 0), 10, zone)
		eq(reason, "Embedded", "ray started inside geometry")

		-- The ground the ray hit is never its own obstruction, and the probe sits above the ground
		local ignoredGround, probeY
		sys.world.obstructed = function(position, _, ignore)
			ignoredGround, probeY = ignore, position.Y
			return false
		end
		truthy(sys.placement:TryCandidate(zone, rng), "ground alone doesn't obstruct")
		eq(ignoredGround, "Ground", "ground passed as ignored")
		truthy(probeY > sys.config.Placement.ObstructionRadius, "probe clears the floor")

		sys.world.obstructed = function()
			return true
		end
		_, reason = sys.placement:TryCandidate(zone, rng)
		eq(reason, "Obstructed", "obstructed")
	end)

	it("keeps clearance from pickups and characters and stays inside the zone", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		truthy(sys.spawnAt("Meadow", 0, 0), "first")
		local _, reason = sys.spawnAt("Meadow", 1, 1)
		eq(reason, "PlacementRejected", "too close to pickup")

		sys.world.characters = { Vector3.new(10, 2, 10) }
		_, reason = sys.spawnAt("Meadow", 10, 10)
		eq(reason, "PlacementRejected", "too close to character")

		-- An anchor outside the zone's bounds is rejected after the ground hit
		local _, zone = sys.addZone("Small", { Position = Vector3.new(200, 5, 0), Size = Vector3.new(10, 10, 10) })
		sys.zones._anchors.Small = { { Position = Vector3.new(260, 1, 0) } }
		local position, anchorReason = sys.placement:TryCandidate(zone, TestKit.FakeRandom())
		eq(position, nil, "outside position")
		eq(anchorReason, "OutsideZone", "reason")
	end)

	it("prefers authored anchors", function()
		local sys = TestKit.System()
		local _, zone = sys.addZone("Meadow")
		sys.zones._anchors.Meadow = { { Position = Vector3.new(7, 0.5, -3) } }
		local position = sys.placement:TryCandidate(zone, TestKit.FakeRandom())
		eq(position.X, 7, "anchor x")
		eq(position.Z, -3, "anchor z")
	end)

	it("never spawns on an active trap or exclusion volume", function()
		local trapVolumes = { { CFrame = CFrame.new(0, 1, 0), Size = Vector3.new(4, 2, 4) } }
		local traps = TestKit.ExclusionProviders.VolumeProvider("Traps", function()
			return trapVolumes
		end)
		local structure = TestKit.ExclusionProviders.VolumeProvider("Structures", function()
			return { { CFrame = CFrame.new(15, 3, 15), Size = Vector3.new(6, 6, 6) } }
		end)
		local sys = TestKit.System({ traps = traps, exclusions = { structure } })
		local _, zone = sys.addZone("Meadow")

		local position, reason = sys.placement:Validate(Vector3.new(5, 10, 0), 50, zone) -- within TrapPadding
		eq(position, nil, "near trap")
		eq(reason, "Trap", "reason")
		position, reason = sys.placement:Validate(Vector3.new(15, 10, 15), 50, zone)
		eq(reason, "Excluded", "structure")
		truthy(sys.placement:Validate(Vector3.new(-15, 10, -15), 50, zone), "clear spot")
	end)

	it("the placeholder trap provider is labelled as such", function()
		local provider = TestKit.ExclusionProviders.NoTrapsProvider()
		eq(provider.IsPlaceholder, true, "placeholder flag")
		falsy(provider:IsExcluded(Vector3.new(), 10), "excludes nothing")
	end)
end)

describe("Population budgets", function()
	local profile = { BasePickups = 3, PickupsPerExtraPlayer = 2, MaxPickups = 8 }
	local schedule = { PopulationCap = 4, RatePerExtraPlayer = 0.5, MaxRateMultiplier = 3, SpawnInterval = { Min = 2, Max = 2 } }

	it("scales budget with zone population up to the cap", function()
		eq(ZoneSpawner.ComputeBudget(profile, 0, schedule), 0, "empty")
		eq(ZoneSpawner.ComputeBudget(profile, 1, schedule), 3, "one")
		eq(ZoneSpawner.ComputeBudget(profile, 2, schedule), 5, "two")
		eq(ZoneSpawner.ComputeBudget(profile, 3, schedule), 7, "three")
		eq(ZoneSpawner.ComputeBudget(profile, 20, schedule), 8, "capped by MaxPickups")
	end)

	it("shortens the interval with population, capped", function()
		local rng = TestKit.FakeRandom()
		eq(ZoneSpawner.ComputeInterval(schedule, 1, rng), 2, "one player")
		eq(ZoneSpawner.ComputeInterval(schedule, 3, rng), 1, "three players")
		eq(ZoneSpawner.ComputeInterval(schedule, 50, rng), 2 / 2.5, "population cap")
	end)

	it("one zone timer serves many players; supply never exceeds the budget", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		for index = 1, 3 do
			sys.addPlayer(`P{index}`, Vector3.new(-18 + index, 3, -18))
		end
		sys.zones:Poll()
		eq(sys.zones:GetPopulation("Meadow"), 3, "population")
		local budget = ZoneSpawner.ComputeBudget(sys.config.Zones.Default, 3, sys.config.Schedule)

		for step = 0, 400 do
			sys.spawner:Step(step * 0.25)
		end
		eq(sys.eggRegistry:CountZone("Meadow"), budget, "filled exactly to budget")

		-- Two players leave; the budget drops and no new pickups appear until it frees up
		sys.removePlayer(sys.players[1])
		sys.removePlayer(sys.players[2])
		sys.zones:Poll()
		local count = sys.eggRegistry:CountZone("Meadow")
		for step = 401, 500 do
			sys.spawner:Step(step * 0.25)
		end
		eq(sys.eggRegistry:CountZone("Meadow"), count, "no growth above the smaller budget")
	end)

	it("an empty zone spawns nothing and the server cap holds", function()
		local config = TestKit.Config()
		config.ServerMaxPickups = 2
		local sys = TestKit.System({ config = config })
		sys.addZone("Meadow")
		for step = 0, 100 do
			sys.spawner:Step(step)
		end
		eq(sys.eggRegistry:Count(), 0, "no players, no spawns")

		sys.addPlayer("A", Vector3.new(-19, 3, -19))
		sys.zones:Poll()
		for step = 101, 300 do
			sys.spawner:Step(step)
		end
		eq(sys.eggRegistry:CountOrdinary(), 2, "server-wide cap")
	end)

	it("weighted choice follows configured weights", function()
		local distribution = {
			{ ItemTypeId = "SnowEgg", Weight = 3 },
			{ ItemTypeId = "IceEgg", Weight = 1 },
		}
		local rng = TestKit.FakeRandom()
		rng:Push(0.0, 0.74, 0.76, 0.999)
		eq(ZoneSpawner.PickWeighted(distribution, rng).ItemTypeId, "SnowEgg", "0.0")
		eq(ZoneSpawner.PickWeighted(distribution, rng).ItemTypeId, "SnowEgg", "0.74")
		eq(ZoneSpawner.PickWeighted(distribution, rng).ItemTypeId, "IceEgg", "0.76")
		eq(ZoneSpawner.PickWeighted(distribution, rng).ItemTypeId, "IceEgg", "0.999")
	end)
end)
