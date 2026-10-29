local TestKit = require("../TestKit")
local describe, it, eq, truthy, falsy = TestKit.describe, TestKit.it, TestKit.eq, TestKit.truthy, TestKit.falsy

local ZoneSpawner = TestKit.ZoneSpawner

-- Queue a weighted roll that picks IceEgg from the fixture distribution (SnowEgg 3, IceEgg 1)
local function pushIceRoll(sys)
	sys.rng:Push(0.9)
end

describe("Placement", function()
	it("stops after PlacementAttempts when geometry is invalid, then succeeds later", function()
		local sys = TestKit.System()
		sys.addZone("Lake")
		local player = sys.addPlayer("A", Vector3.new(-19, 3, -19))
		sys.world.material = "Water"
		local record, reason = sys.spawner:SpawnFor(player, "Lake")
		eq(record, nil, "spawned on water")
		eq(reason, "PlacementExhausted", "reason")
		eq(sys.world.raycasts, sys.configs.spawnerConfig.PlacementAttempts, "bounded attempts")
		eq(sys.eggRegistry:Count(), 0, "nothing registered")

		sys.world.material = "Snow"
		truthy(sys.spawner:SpawnFor(player, "Lake"), "next opportunity")
	end)

	it("rejects steep slopes, blocked surfaces, no ground, embedded rays, and obstructions", function()
		local sys = TestKit.System()
		local _, zone = sys.addZone("Meadow")
		local rng = TestKit.FakeRandom()
		local owner = 1

		sys.world.normal = Vector3.new(1, 1, 0).Unit -- 45 degrees
		local _, reason = sys.placement:TryCandidate(zone, rng, owner)
		eq(reason, "TooSteep", "slope")
		sys.world.normal = Vector3.new(0, 1, 0)

		sys.world.blocked = true
		_, reason = sys.placement:TryCandidate(zone, rng, owner)
		eq(reason, "BlockedSurface", "blocked")
		sys.world.blocked = false

		sys.world.noGround = true
		_, reason = sys.placement:TryCandidate(zone, rng, owner)
		eq(reason, "NoGround", "no ground")
		sys.world.noGround = false

		_, reason = sys.placement:Validate(Vector3.new(0, 0.01, 0), 10, zone, owner)
		eq(reason, "Embedded", "ray started inside geometry")

		-- The ground the ray hit is never its own obstruction, and the probe sits above the ground
		local ignoredGround, probeY
		sys.world.obstructed = function(position, _, ignore)
			ignoredGround, probeY = ignore, position.Y
			return false
		end
		truthy(sys.placement:TryCandidate(zone, rng, owner), "ground alone doesn't obstruct")
		eq(ignoredGround, "Ground", "ground passed as ignored")
		truthy(probeY > sys.configs.placementConfig.ObstructionRadius, "probe clears the floor")

		sys.world.obstructed = function()
			return true
		end
		_, reason = sys.placement:TryCandidate(zone, rng, owner)
		eq(reason, "Obstructed", "obstructed")
	end)

	it("keeps clearance from the owner's own eggs and from every character, and stays inside the zone", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		truthy(sys.spawnAt(a, "Meadow", 0, 0), "first")
		local _, reason, detail = sys.spawnAt(a, "Meadow", 1, 1)
		eq(reason, "PlacementRejected", "too close to own egg")
		eq(detail, "NearPickup", "detail")

		sys.world.characters = { Vector3.new(10, 2, 10) }
		_, reason, detail = sys.spawnAt(a, "Meadow", 10, 10)
		eq(detail, "NearCharacter", "too close to a character (any player's)")

		-- An anchor outside the zone's bounds is rejected after the ground hit
		local _, zone = sys.addZone("Small", { Position = Vector3.new(200, 5, 0), Size = Vector3.new(10, 10, 10) })
		sys.zones._anchors.Small = { { Position = Vector3.new(260, 1, 0) } }
		local position, anchorReason = sys.placement:TryCandidate(zone, TestKit.FakeRandom(), a.UserId)
		eq(position, nil, "outside position")
		eq(anchorReason, "OutsideZone", "reason")
	end)

	it("other owners' eggs don't take up space", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local b = sys.addPlayer("B", Vector3.new(0, 3, 0))
		truthy(sys.spawnAt(a, "Meadow", 0, 0), "A's egg")
		truthy(sys.spawnAt(b, "Meadow", 1, 1), "B's egg right beside it")
	end)

	it("prefers authored anchors", function()
		local sys = TestKit.System()
		local _, zone = sys.addZone("Meadow")
		sys.zones._anchors.Meadow = { { Position = Vector3.new(7, 0.5, -3) } }
		local position = sys.placement:TryCandidate(zone, TestKit.FakeRandom(), 1)
		eq(position.X, 7, "anchor x")
		eq(position.Z, -3, "anchor z")
	end)

	it("never spawns on an active trap or exclusion volume", function()
		local traps = TestKit.ExclusionProviders.VolumeProvider("Traps", function()
			return { { CFrame = CFrame.new(0, 1, 0), Size = Vector3.new(4, 2, 4) } }
		end)
		local structure = TestKit.ExclusionProviders.VolumeProvider("Structures", function()
			return { { CFrame = CFrame.new(15, 3, 15), Size = Vector3.new(6, 6, 6) } }
		end)
		local sys = TestKit.System({ traps = traps, exclusions = { structure } })
		local _, zone = sys.addZone("Meadow")

		local position, reason = sys.placement:Validate(Vector3.new(5, 10, 0), 50, zone, 1) -- within TrapPadding
		eq(position, nil, "near trap")
		eq(reason, "Trap", "reason")
		_, reason = sys.placement:Validate(Vector3.new(15, 10, 15), 50, zone, 1)
		eq(reason, "Excluded", "structure")
		truthy(sys.placement:Validate(Vector3.new(-15, 10, -15), 50, zone, 1), "clear spot")
	end)

	it("the placeholder trap provider is labelled as such", function()
		local provider = TestKit.ExclusionProviders.NoTrapsProvider()
		eq(provider.IsPlaceholder, true, "placeholder flag")
		falsy(provider:IsExcluded(Vector3.new(), 10), "excludes nothing")
	end)
end)

describe("Per-player caps", function()
	it("MaxPickups caps one owner in one zone; MaxPickupsPerPlayer caps them across zones", function()
		local sys = TestKit.System() -- MaxPickups 4, MaxPickupsPerPlayer 6
		sys.addZone("West", { Position = Vector3.new(-100, 5, 0) })
		sys.addZone("East", { Position = Vector3.new(100, 5, 0) })
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		for index = 1, 4 do
			truthy(sys.spawnAt(a, "West", -115 + index * 6, 0), `west {index}`)
		end
		local _, reason = sys.spawner:SpawnFor(a, "West")
		eq(reason, "ZoneCap", "zone cap")
		eq(sys.world.raycasts, 4, "a capped opportunity costs no raycasts")

		truthy(sys.spawnAt(a, "East", 90, 0), "east 1")
		truthy(sys.spawnAt(a, "East", 100, 0), "east 2")
		_, reason = sys.spawner:SpawnFor(a, "East")
		eq(reason, "PlayerCap", "total cap")
		eq(sys.eggRegistry:CountOwner(a.UserId), 6, "owner count")
		eq(sys.eggRegistry:CountOwnerZone(a.UserId, "East"), 2, "owner zone count")
	end)

	it("EggService confirms caps last, even when called directly", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		for index = 1, 4 do
			sys.spawnAt(a, "Meadow", -15 + index * 6, 0)
		end
		local record, reason = sys.spawnAt(a, "Meadow", 10, 10)
		eq(record, nil, "registered over cap")
		eq(reason, "ZoneCap", "reason")
	end)

	it("one player's caps never block another player", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local b = sys.addPlayer("B", Vector3.new(0, 3, 0))
		for index = 1, 4 do
			sys.spawnAt(a, "Meadow", -15 + index * 6, 0)
		end
		truthy(sys.spawner:SpawnFor(b, "Meadow"), "B spawns while A is capped")
	end)

	it("capacity returns when an egg expires", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		for index = 1, 4 do
			sys.spawnAt(a, "Meadow", -15 + index * 6, 0)
		end
		falsy(sys.eggs:HasCapacity(a.UserId, "Meadow"), "capped")
		sys.time.advance(sys.configs.pickupConfig.PickupLifetime)
		truthy(sys.eggs:HasCapacity(a.UserId, "Meadow"), "free again after expiry")
	end)
end)

describe("Templates", function()
	it("a template missing after startup spawns the egg with the fallback visual and warns once", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		sys.templates.missing.IceEgg = true
		pushIceRoll(sys)
		local record = sys.spawner:SpawnFor(a, "Meadow")
		truthy(record, "spawned")
		eq(record.ItemTypeId, "IceEgg", "keeps its identity and reward")
		eq(#sys.warnings, 1, "one warning")
		truthy(sys.warnings[1]:find("MODEL OF IceEgg doesnt exist", 1, true), "required wording")
		truthy(sys.warnings[1]:find("SnowEgg", 1, true), "names the replacement")
	end)

	it("warns once per attempt, not once per placement retry", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		sys.templates.missing.IceEgg = true
		sys.world.material = "Water"
		pushIceRoll(sys)
		local _, reason = sys.spawner:SpawnFor(a, "Meadow")
		eq(reason, "PlacementExhausted", "every placement failed")
		eq(#sys.warnings, 1, "still one warning")
	end)

	it("skips the opportunity when the fallback is missing too", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		sys.templates.missing.IceEgg = true
		sys.templates.missing.SnowEgg = true
		pushIceRoll(sys)
		local record, reason = sys.spawner:SpawnFor(a, "Meadow")
		eq(record, nil, "spawned")
		eq(reason, "ModelMissing", "reason")
		eq(sys.world.raycasts, 0, "no placement work")
		truthy(sys.warnings[1]:find("MODEL OF SnowEgg doesnt exist", 1, true), "fallback named as missing")
	end)
end)

describe("Distribution", function()
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

	it("zones without their own profile use the fallback profile", function()
		local sys = TestKit.System()
		eq(sys.spawner:GetProfile("Anywhere"), sys.configs.zoneIdConfig.Zones.Default, "fallback")
		sys.configs.zoneIdConfig.FallbackZoneProfile = false
		eq(sys.spawner:GetProfile("Anywhere"), nil, "no fallback")
	end)
end)

-- Fixture timing: SpawnInterval 1..5, SpawnIntervalCurve 0.9, BasePickups 3, MaxPickups 4, MaxPickupsPerPlayer 6,
-- FirstSpawnDelay 0.5, ReentryCreditMultiplier 5 (25 s window)
local function inZone(sys, zoneId, x)
	local player = sys.addPlayer("A", Vector3.new(x or 0, 3, 0))
	sys.zones:Poll()
	eq(sys.zones:GetZoneOf(player), zoneId, "player placed in zone")
	return player
end

local function moveTo(sys, player, x)
	sys.roots[player] = Vector3.new(x, 3, 0)
	sys.zones:Poll()
end

describe("Spawn timing", function()
	it("interval(n) stays at Min up to BasePickups, then climbs toward Max", function()
		local config = TestKit.Configs().spawnerConfig
		for count = 0, 3 do
			eq(ZoneSpawner.ComputeInterval(config, count), 1, `count {count}`)
		end
		truthy(math.abs(ZoneSpawner.ComputeInterval(config, 4) - 1.4) < 1e-9, "one past base: 5 - 4 * 0.9")
		truthy(math.abs(ZoneSpawner.ComputeInterval(config, 5) - 1.76) < 1e-9, "two past base: 5 - 4 * 0.81")
		truthy(ZoneSpawner.ComputeInterval(config, 200) < 5, "never reaches Max")
		config.SpawnIntervalCurve = 1
		eq(ZoneSpawner.ComputeInterval(config, 50), 1, "r = 1 keeps every wait at Min")
	end)

	it("first egg FirstSpawnDelay after entering, then interval(n) after each egg, pausing at the zone cap", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		local player = inZone(sys, "Meadow")
		local function count()
			return sys.eggRegistry:CountOwnerZone(player.UserId, "Meadow")
		end

		sys.spawner:Step(0)
		eq(sys.spawner:GetSchedule(player).NextAt, 0.5, "first egg due at entry + 0.5")
		sys.spawner:Step(0.49)
		eq(count(), 0, "not before")
		sys.spawner:Step(0.5)
		eq(count(), 1, "first egg")
		eq(sys.spawner:GetSchedule(player).NextAt, 1.5, "next = Min below BasePickups")
		sys.spawner:Step(1.5)
		sys.spawner:Step(2.5)
		eq(count(), 3, "refilling at Min")
		sys.spawner:Step(3.5)
		eq(count(), 4, "fourth egg reaches MaxPickups")
		sys.spawner:Step(4.9)
		eq(sys.spawner:GetSchedule(player).NextAt, nil, "paused at the cap")
	end)

	it("resumes with one interval after capacity returns, never a burst of missed spawns", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		local player = inZone(sys, "Meadow")
		local eggs = {}
		for index = 1, 4 do
			table.insert(eggs, sys.spawnAt(player, "Meadow", -15 + index * 6, 0))
		end
		sys.spawner:Step(0)
		eq(sys.spawner:GetSchedule(player).NextAt, nil, "paused while capped")
		for now = 1, 40 do
			sys.spawner:Step(now)
		end

		sys.eggs:Despawn(eggs[1].PickupId) -- capacity returns (same path as expiry)
		sys.spawner:Step(50)
		eq(sys.spawner:GetSchedule(player).NextAt, 51, "waits interval(3) = Min from now")
		sys.spawner:Step(50.9)
		eq(sys.eggRegistry:CountOwnerZone(player.UserId, "Meadow"), 3, "nothing early")
		sys.spawner:Step(51)
		eq(sys.eggRegistry:CountOwnerZone(player.UserId, "Meadow"), 4, "exactly one egg after a long pause")
	end)

	it("leaving and quickly re-entering keeps the remaining wait instead of resetting it", function()
		local sys = TestKit.System()
		sys.addZone("West", { Position = Vector3.new(-100, 5, 0) })
		sys.addZone("East", { Position = Vector3.new(100, 5, 0) })
		local player = inZone(sys, "West", -100)
		sys.spawner:Step(0)
		sys.spawner:Step(0.5) -- West egg 1; next due 1.5
		moveTo(sys, player, 100)
		sys.spawner:Step(1.0) -- leaves West with 0.5 s left
		eq(sys.spawner:GetSchedule(player).ZoneId, "East", "East has its own schedule")
		eq(sys.spawner:GetSchedule(player).NextAt, 1.5, "fresh entry into East")
		moveTo(sys, player, -100)
		sys.spawner:Step(1.2)
		eq(sys.spawner:GetSchedule(player).NextAt, 1.5, "West resumes: 0.5 left - 0.2 away = due at 1.5")
	end)

	it("a wait that ran out while away gives one egg on re-entry, then a fresh cycle", function()
		local sys = TestKit.System()
		sys.addZone("West", { Position = Vector3.new(-100, 5, 0) })
		local player = inZone(sys, "West", -100)
		sys.spawner:Step(0)
		sys.spawner:Step(0.5) -- egg 1; next due 1.5
		moveTo(sys, player, 0) -- outside every zone
		sys.spawner:Step(1.0)
		eq(sys.spawner:GetSchedule(player), nil, "no schedule outside zones")
		for now = 1.25, 2.75, 0.25 do
			sys.spawner:Step(now)
		end
		eq(sys.eggRegistry:CountOwner(player.UserId), 1, "nothing spawns outside zones")
		moveTo(sys, player, -100)
		sys.spawner:Step(3.0)
		eq(sys.eggRegistry:CountOwnerZone(player.UserId, "West"), 2, "one egg right away, no backlog")
		eq(sys.spawner:GetSchedule(player).NextAt, 4.0, "then interval(2) = Min")
	end)

	it("re-entry credit expires after SpawnInterval.Max * ReentryCreditMultiplier", function()
		local sys = TestKit.System()
		sys.addZone("West", { Position = Vector3.new(-100, 5, 0) })
		local player = inZone(sys, "West", -100)
		sys.spawner:Step(0)
		sys.spawner:Step(0.5)
		moveTo(sys, player, 0)
		sys.spawner:Step(1.0)
		moveTo(sys, player, -100)
		sys.spawner:Step(27.0) -- 26 s away > 25 s window
		eq(sys.spawner:GetSchedule(player).NextAt, 27.5, "treated as a fresh entry")
	end)

	it("death resets schedules and saved waits; a dead player gets nothing; eggs stay", function()
		local sys = TestKit.System()
		sys.addZone("West", { Position = Vector3.new(-100, 5, 0) })
		local player = inZone(sys, "West", -100)
		sys.spawner:Step(0)
		sys.spawner:Step(0.5)
		sys.spawner:Step(1.0)
		moveTo(sys, player, 0)
		sys.spawner:Step(1.2) -- saved wait for West

		sys.spawner:ResetPlayer(player) -- Humanoid.Died
		sys.roots[player] = nil
		sys.zones:Poll()
		for now = 1.5, 5, 0.25 do
			sys.spawner:Step(now)
		end
		eq(sys.spawner:GetSchedule(player), nil, "no schedule while dead")
		eq(sys.eggRegistry:CountOwner(player.UserId), 1, "existing egg kept, none added")

		moveTo(sys, player, -100) -- respawned in West
		sys.spawner:Step(6.0)
		eq(sys.spawner:GetSchedule(player).NextAt, 6.5, "fresh entry, saved wait discarded")
	end)

	it("players' schedules are independent: one capped player doesn't stop another", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		local a = inZone(sys, "Meadow")
		local b = sys.addPlayer("B", Vector3.new(5, 3, 5))
		sys.zones:Poll()
		for index = 1, 4 do
			sys.spawnAt(a, "Meadow", -15 + index * 6, 0)
		end
		sys.spawner:Step(0)
		sys.spawner:Step(0.5)
		eq(sys.eggRegistry:CountOwner(b.UserId), 1, "B spawned")
		eq(sys.eggRegistry:CountOwner(a.UserId), 4, "A unchanged")
		eq(sys.spawner:GetSchedule(a).NextAt, nil, "A paused")
	end)

	it("leaving the server or removing the zone drops the schedules", function()
		local sys = TestKit.System()
		local part = sys.addZone("Meadow")
		local a = inZone(sys, "Meadow")
		local b = sys.addPlayer("B", Vector3.new(5, 3, 5))
		sys.zones:Poll()
		sys.spawner:Step(0)
		sys.removePlayer(a)
		eq(sys.spawner:GetSchedule(a), nil, "A dropped")
		sys.zones:Unregister(part)
		eq(sys.spawner:GetSchedule(b), nil, "zone schedules dropped")
	end)

	it("fills a zone over time on the shared tick and holds at the cap", function()
		local sys = TestKit.System()
		sys.addZone("Meadow")
		local player = inZone(sys, "Meadow")
		sys.run(20)
		eq(sys.eggRegistry:CountOwnerZone(player.UserId, "Meadow"), 4, "reached MaxPickups and held")
	end)
end)
