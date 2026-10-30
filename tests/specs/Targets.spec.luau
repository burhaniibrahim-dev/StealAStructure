local TestKit = require("../TestKit")
local describe, it, eq, truthy, falsy = TestKit.describe, TestKit.it, TestKit.eq, TestKit.truthy, TestKit.falsy

local ConfigValidator = TestKit.ConfigValidator
local TargetService = TestKit.TargetService
local TargetPlacement = TestKit.TargetPlacement
local TargetVisuals = require("../../src/ReplicatedStorage/Shared/Features/Visuals/TargetVisuals")

-- Fixture: Meadow is a 40 x 40 Block zone centred on (0, 5, 0) over flat ground at y = 0.
-- Red: Health 100..100, Scale 2..2, RadiusGrowth 2..2; Nothing weight 1. TargetTime 5, GraceTime 0.5,
-- Appear/Disappear 0.1, 60 candidates, 5 run batches, radius 5, growth limit 10, clearance 4, TickInterval 0.25

local function near(actual, expected, label)
	if math.abs(actual - expected) > 1e-6 then
		error(`{label or "value"}: expected {expected}, got {actual}`, 2)
	end
end

local function setup(options)
	local sys = TestKit.TargetSystem(options)
	sys.zonePart = sys.addZone("Meadow")
	return sys
end

local function redEntry(sys)
	return sys.configs.zoneIdConfig.Zones.Default.Targets[1]
end

local function spawnStarter(sys, x, z)
	sys.pushPosition("Meadow", x, z)
	return sys.targets:TrySpawnStarter("Meadow", redEntry(sys), sys.time.t)
end

-- Claims a fresh starter at (x, z); returns the run and the starter
local function startRun(sys, player, x, z)
	local starter = assert(spawnStarter(sys, x or 0, z or 0), "starter placed")
	sys.step(0.15)
	local ok, outcome = sys.targets:ApplyHit(player, starter.TargetId, 1)
	assert(ok, outcome)
	return sys.targetRegistry:GetRunOf(player.UserId), starter
end

local function current(sys, run)
	return run.TargetId and sys.targetRegistry:Get(run.TargetId)
end

-- Waits out the exit transition so the next target is placed; returns it
local function nextTarget(sys, run)
	sys.step(0.15)
	return current(sys, run)
end

-- Acknowledges and waits out the damage lock
local function reveal(sys, player, target)
	assert(sys.targets:HandleShown(player, target.TargetId), "acknowledged")
	sys.step(0.12)
end

describe("Target config", function()
	it("the egg distribution moved under Eggs unchanged", function()
		local IdConfig = require("../../src/ServerScriptService/Configs/Zones/IdConfig")
		local eggs = IdConfig.Zones.Default.Eggs
		eq(#eggs, 3, "entries")
		eq(eggs[1].ItemTypeId .. eggs[1].Weight .. eggs[1].Amount.Min .. eggs[1].Amount.Max, "Common7512", "common")
		eq(eggs[2].ItemTypeId .. eggs[2].Weight .. eggs[2].Amount.Min .. eggs[2].Amount.Max, "Rare2011", "rare")
		eq(eggs[3].ItemTypeId .. eggs[3].Weight .. eggs[3].Amount.Min .. eggs[3].Amount.Max, "Epic511", "epic")
		eq(IdConfig.FallbackZoneProfile, "Default", "fallback kept")

		local sys = TestKit.System()
		eq(sys.spawner:GetEggDistribution("Anywhere"), sys.configs.zoneIdConfig.Zones.Default.Eggs, "egg reader")
	end)

	it("rejects bad Targets entries, old flat profiles, and a type named Nothing", function()
		local inputs = TestKit.Configs()
		inputs.itemCatalog = TestKit.ItemCatalog()
		local targets = inputs.zoneIdConfig.Zones.Default.Targets
		targets[1].Health = { Min = 0, Max = 10 }
		targets[1].Scale = { Min = 1.5, Max = 2 }
		targets[2] = { TargetTypeId = "Blue", Weight = 1 }
		inputs.zoneIdConfig.Zones.Old = { { ItemTypeId = "SnowEgg", Weight = 1, Amount = { Min = 1, Max = 1 } } }
		inputs.targetConfig.Types.Nothing = { ModelName = "X" }
		inputs.targetConfig.PlacementCandidates = 0
		local ok, errors = ConfigValidator.validate(inputs)
		falsy(ok, "valid")
		local text = table.concat(errors, "\n")
		truthy(text:find("Targets[1].Health.Min must be >= 1", 1, true), "health")
		truthy(text:find("Targets[1].Scale must have whole", 1, true), "integer scale")
		truthy(text:find('"Blue" is not in TargetConfig.Types', 1, true), "unknown type")
		truthy(text:find("IdConfig.Zones.Old has unknown key 1", 1, true), "old flat profile")
		truthy(text:find('"Nothing" is reserved', 1, true), "reserved type")
		truthy(text:find("TargetConfig.PlacementCandidates", 1, true), "candidates")
	end)

	it("time remaining is clamped to TargetTime, and the bonus uses health removed", function()
		eq(TargetService.TimeRemaining(10.5, 5, 5), 5, "grace hidden")
		eq(TargetService.TimeRemaining(10.5, 7.5, 5), 3, "counting down")
		eq(TargetService.TimeRemaining(10.5, 11, 5), 0, "never negative")
		eq(100 + TargetService.CompletionBonus(100, 3), 250, "worked example")
	end)
end)

describe("Public starter schedule", function()
	it("waits FirstSpawnDelay, then one opportunity per tick; Nothing uses it up", function()
		local sys = setup()
		sys.addPlayer("A", Vector3.new(0, 3, 0))
		sys.zones:Poll()
		sys.targetSpawner:Step(0)
		sys.time.advance(0.25)
		sys.targetSpawner:Step(sys.time.t)
		eq(sys.targetRegistry:CountStarters("Meadow"), 0, "before the first delay")

		sys.time.advance(0.25)
		sys.rng:Push(0.9) -- roll 1.8 of 2: Nothing
		sys.targetSpawner:Step(sys.time.t)
		eq(sys.targetRegistry:CountStarters("Meadow"), 0, "Nothing spawned nothing")

		sys.time.advance(0.25)
		sys.rng:Push(0.1) -- Red
		sys.targetSpawner:Step(sys.time.t)
		eq(sys.targetRegistry:CountStarters("Meadow"), 1, "next tick spawned")
	end)

	it("only zones with players spawn, and an emptied zone's starters still expire", function()
		local sys = setup()
		local player = sys.addPlayer("A", Vector3.new(500, 3, 0))
		sys.zones:Poll()
		sys.targetSpawner:Step(0)
		eq(sys.targetSpawner:GetSchedule("Meadow"), nil, "empty zone has no schedule")

		local starter = spawnStarter(sys, 0, 0)
		sys.roots[player] = Vector3.new(0, 3, 0)
		sys.zones:Poll()
		sys.targetSpawner:Step(0)
		truthy(sys.targetSpawner:GetSchedule("Meadow"), "occupied zone scheduled")

		sys.roots[player] = Vector3.new(500, 3, 0)
		sys.zones:Poll()
		sys.targetSpawner:Step(0)
		eq(sys.targetSpawner:GetSchedule("Meadow"), nil, "dropped on emptying")
		truthy(sys.targetRegistry:Get(starter.TargetId), "starter still live")
		sys.step(5.15) -- appear 0.1 + lifetime 5
		eq(sys.targetRegistry:Get(starter.TargetId), nil, "expired after lifetime")
		eq(starter.Model.Attributes.State, "Leaving", "exit animation")
		sys.step(0.15)
		truthy(starter.Model.Destroyed, "model destroyed after the exit")
	end)

	it("keeps a selected type after failed placement and retries it without rerolling", function()
		local sys = setup()
		sys.addPlayer("A", Vector3.new(0, 3, 0))
		sys.zones:Poll()
		sys.targetSpawner:Step(0)
		sys.time.advance(0.5)
		sys.world.noGround = true
		sys.rng:Push(0.1) -- Red
		sys.targetSpawner:Step(sys.time.t)
		eq(sys.world.raycasts, 60, "one batch of 60 candidates")
		eq(sys.targetSpawner:GetSchedule("Meadow").Pending, redEntry(sys), "type kept")

		sys.world.noGround = false
		sys.time.advance(0.25)
		sys.rng:Push(0.9) -- would roll Nothing; the kept type means no roll happens
		sys.targetSpawner:Step(sys.time.t)
		eq(sys.targetRegistry:CountStarters("Meadow"), 1, "kept type placed")
		eq(sys.targetSpawner:GetSchedule("Meadow").Pending, nil, "cleared")
	end)

	it("an emptied zone discards its kept type", function()
		local sys = setup()
		local player = sys.addPlayer("A", Vector3.new(0, 3, 0))
		sys.zones:Poll()
		sys.targetSpawner:Step(0)
		sys.time.advance(0.5)
		sys.world.noGround = true
		sys.rng:Push(0.1)
		sys.targetSpawner:Step(sys.time.t)
		truthy(sys.targetSpawner:GetSchedule("Meadow").Pending, "kept")
		sys.roots[player] = Vector3.new(500, 3, 0)
		sys.zones:Poll()
		sys.targetSpawner:Step(sys.time.t)
		sys.roots[player] = Vector3.new(0, 3, 0)
		sys.zones:Poll()
		sys.targetSpawner:Step(sys.time.t)
		eq(sys.targetSpawner:GetSchedule("Meadow").Pending, nil, "fresh schedule")
	end)

	it("pauses at 3 starters per zone, ignores run targets, and resumes on the following tick", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local b = sys.addPlayer("B", Vector3.new(0, 3, 0))
		sys.zones:Poll()
		local run = startRun(sys, a, -15, -15)
		truthy(nextTarget(sys, run), "run target placed")

		spawnStarter(sys, 0, 0)
		spawnStarter(sys, 10, 10)
		local third = spawnStarter(sys, -10, 10)
		eq(sys.targetRegistry:CountStarters("Meadow"), 3, "run target not counted")
		local _, reason = spawnStarter(sys, 15, -15)
		eq(reason, "ZoneCap", "hard cap")

		sys.targetSpawner:Step(sys.time.t)
		eq(sys.targetSpawner:GetSchedule("Meadow").NextAt, nil, "paused")

		sys.step(0.15)
		truthy(sys.targets:ApplyHit(b, third.TargetId, 1), "claim frees a slot")
		sys.targetSpawner:Step(sys.time.t)
		eq(sys.targetRegistry:CountStarters("Meadow"), 2, "no burst on the freeing tick")
		local nextAt = sys.targetSpawner:GetSchedule("Meadow").NextAt
		truthy(nextAt and nextAt > sys.time.t, "resumes next tick")
	end)

	it("a type whose model is missing uses the opportunity up and warns once", function()
		local sys = setup()
		sys.targetWorld.missing.Target = true
		local _, reason = spawnStarter(sys, 0, 0)
		eq(reason, "ModelMissing", "disabled")
		spawnStarter(sys, 0, 0)
		local warnings = 0
		for _, message in sys.warnings do
			if message:find("MODEL OF Target", 1, true) then
				warnings += 1
			end
		end
		eq(warnings, 1, "one warning")
		sys.targetWorld.missing.Target = nil
		truthy(spawnStarter(sys, 0, 0), "re-enabled when the model returns")
	end)
end)

describe("Target placement", function()
	it("target spacing is full 3D distance with the boundary at exactly 4", function()
		local sys = setup()
		local zone = sys.zones:GetZone("Meadow")
		spawnStarter(sys, 0, 0)
		truthy(sys.targetPlacement:ValidateAt(Vector3.new(4, 0, 0), zone, nil), "exactly 4 is allowed")
		local _, reason = sys.targetPlacement:ValidateAt(Vector3.new(3.999, 0, 0), zone, nil)
		eq(reason, "NearTarget", "under 4 rejected")
	end)

	it("targets keep the 6-stud egg clearance, measured in 3D", function()
		local sys = setup()
		local zone = sys.zones:GetZone("Meadow")
		local owner = sys.addPlayer("Owner", Vector3.new(0, 3, 0))
		sys.spawnAt(owner, "Meadow", -10, -10) -- rests at y = 1
		-- 5.9 horizontally is sqrt(5.9^2 + 1) = 5.98 in 3D: too close. 5.95 is 6.03: allowed
		local _, reason = sys.targetPlacement:ValidateAt(Vector3.new(-4.1, 0, -10), zone, nil)
		eq(reason, "NearEgg", "under 6 in 3D")
		truthy(sys.targetPlacement:ValidateAt(Vector3.new(-4.05, 0, -10), zone, nil), "3D, not horizontal")
		truthy(sys.targetPlacement:ValidateAt(Vector3.new(-5, 0, -10), zone, nil) == nil, "horizontal 5 still rejected")
	end)

	it("eggs keep the 6-stud clearance from live targets, and only from live ones", function()
		local sys = setup()
		local owner = sys.addPlayer("Owner", Vector3.new(0, 3, 0))
		local starter = spawnStarter(sys, 0, 0)
		local record, reason, detail = sys.spawnAt(owner, "Meadow", 5.9, 0) -- egg at y = 1: 3D distance 5.98
		eq(record, nil, "egg beside a target")
		eq(reason, "PlacementRejected", "rejected")
		eq(detail, "Excluded", "by the target exclusion")
		truthy(sys.spawnAt(owner, "Meadow", 0, 6), "6.08 away is fine")

		sys.step(5.3) -- starter expires and leaves the registry
		eq(sys.targetRegistry:Get(starter.TargetId), nil, "starter gone")
		truthy(sys.spawnAt(owner, "Meadow", 5.9, 0), "space free again")
	end)

	it("starters avoid every egg; run targets avoid only their owner's eggs", function()
		local sys = setup()
		local zone = sys.zones:GetZone("Meadow")
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local b = sys.addPlayer("B", Vector3.new(0, 3, 0))
		sys.spawnAt(b, "Meadow", 0, 0)
		local point = Vector3.new(1, 0, 0)
		local _, reason = sys.targetPlacement:ValidateAt(point, zone, nil)
		eq(reason, "NearEgg", "public sees every egg")
		truthy(sys.targetPlacement:ValidateAt(point, zone, a.UserId), "another player's egg doesn't block A")
		_, reason = sys.targetPlacement:ValidateAt(point, zone, b.UserId)
		eq(reason, "NearEgg", "B's own egg blocks B")
	end)

	it("run candidates stay inside both the radius and the zone, never in a higher-priority zone", function()
		local sys = setup()
		local zone = sys.zones:GetZone("Meadow")
		sys.addZone("Inner", {
			attributes = { Priority = 1 },
			Position = Vector3.new(15, 5, 15),
			Size = Vector3.new(6, 10, 6),
		})
		local _, reason = sys.targetPlacement:ValidateAt(Vector3.new(15, 0, 15), zone, nil)
		eq(reason, "OutsideZone", "nested zone owns that point")

		local origin = Vector3.new(18, 0, 0)
		local accepted, outside = 0, 0
		for _ = 1, 300 do
			local position, why = sys.targetPlacement:TryRun(zone, origin, 5, 1, sys.rng)
			if position then
				accepted += 1
				local dx, dz = position.X - origin.X, position.Z - origin.Z
				truthy(math.sqrt(dx * dx + dz * dz) <= 5 + 1e-9, "inside radius")
				truthy(math.abs(position.X) <= 20 and math.abs(position.Z) <= 20, "inside zone")
			elseif why == "OutsideZone" then
				outside += 1
			end
		end
		truthy(accepted > 0 and outside > 0, `both outcomes seen ({accepted}/{outside})`)

		-- A radius larger than the zone samples the zone and checks the radius instead
		for _ = 1, 50 do
			local position, why = sys.targetPlacement:TryRun(zone, Vector3.zero, 100, 1, sys.rng)
			truthy(position or why ~= "OutsideRadius", "zone sampling inside a huge radius")
		end
		truthy(TargetPlacement.ZoneArea(zone) == 1600, "block area")
	end)
end)

describe("Claiming", function()
	it("is locked during the appear animation, scores nothing, and frees the zone slot", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local starter = spawnStarter(sys, 0, 0)
		local ok, reason = sys.targets:ApplyHit(a, starter.TargetId, 1)
		falsy(ok, "claimed while appearing")
		eq(reason, "NotClaimable", "reason")

		sys.step(0.15)
		ok, reason = sys.targets:ApplyHit(a, starter.TargetId, 1)
		truthy(ok, reason)
		local run = sys.targetRegistry:GetRunOf(a.UserId)
		eq(run.Score, 0, "claiming hit scores nothing")
		eq(sys.targetRegistry:CountStarters("Meadow"), 0, "slot freed")
		eq(starter.Model.Attributes.State, "Leaving", "starter exits")
		eq(run.Origin, starter.Position, "origin kept")
		truthy(sys.targets:GetStatus(a).InRun, "status")
	end)

	it("the first claim wins; later claims and a second run are rejected", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local b = sys.addPlayer("B", Vector3.new(0, 3, 0))
		local first = spawnStarter(sys, 0, 0)
		local second = spawnStarter(sys, 10, 10)
		sys.step(0.15)
		truthy(sys.targets:ApplyHit(a, first.TargetId, 1), "A claims")
		local ok, reason = sys.targets:ApplyHit(b, first.TargetId, 1)
		falsy(ok, "B claims the same starter")
		eq(reason, "NotFound", "gone")
		ok, reason = sys.targets:ApplyHit(a, second.TargetId, 1)
		eq(reason, "InRun", "one run per player")
		truthy(sys.targetRegistry:Get(second.TargetId), "second starter untouched")
	end)

	it("rejects players out of range", function()
		local sys = setup()
		local far = sys.addPlayer("Far", Vector3.new(0, 3, 400))
		local starter = spawnStarter(sys, 0, 0)
		sys.step(0.15)
		local _, reason = sys.targets:ApplyHit(far, starter.TargetId, 1)
		eq(reason, "TooFar", "range")
	end)
end)

describe("Acknowledgment and damage", function()
	it("only the owner acknowledges; damage waits for the acknowledgment and the appear lock", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local b = sys.addPlayer("B", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local target = nextTarget(sys, run)
		truthy(target, "placed after the exit transition")
		eq(target.Model.Attributes.Revealed, false, "hidden from spectators")

		local _, reason = sys.targets:ApplyHit(a, target.TargetId, 1)
		eq(reason, "NotRevealed", "no damage before acknowledgment")
		_, reason = sys.targets:HandleShown(b, target.TargetId)
		eq(reason, "NotOwner", "spectator ack")
		truthy(sys.targets:HandleShown(a, target.TargetId), "owner ack")
		eq(target.Model.Attributes.Revealed, true, "revealed")
		_, reason = sys.targets:HandleShown(a, target.TargetId)
		eq(reason, "NotCurrent", "duplicate ignored")

		sys.step(0.05)
		_, reason = sys.targets:ApplyHit(a, target.TargetId, 1)
		eq(reason, "Locked", "appear lock")
		_, reason = sys.targets:ApplyHit(b, target.TargetId, 1)
		eq(reason, "NotOwner", "spectator damage")
		sys.step(0.06)
		local ok = sys.targets:ApplyHit(a, target.TargetId, 1)
		truthy(ok, "damage after AppearDuration")
		eq(target.Health, 99, "health")
	end)

	it("a missing acknowledgment ends the run after 2 x GraceTime with no replacement", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local target = nextTarget(sys, run)
		local created = #sys.targetWorld.models
		sys.step(0.95)
		eq(#sys.settlements, 0, "still waiting at 0.95 s")
		sys.step(0.1)
		eq(#sys.settlements, 1, "settled")
		eq(sys.settlements[1].Reason, "AckTimeout", "reason")
		eq(sys.settlements[1].Paid, nil, "no score, no reward")
		sys.step(1)
		eq(#sys.targetWorld.models, created, "no replacement target")
		local _, reason = sys.targets:HandleShown(a, target.TargetId)
		eq(reason, "NotFound", "late ack ignored")
		falsy(sys.targets:GetStatus(a).InRun, "free to start again")
		eq(sys.targets:GetStatus(a).CooldownEndsAt, 0, "no cooldown")
	end)

	it("an old TargetId never touches the replacement target", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local first = nextTarget(sys, run)
		reveal(sys, a, first)
		sys.targets:ApplyHit(a, first.TargetId, 1000)
		local second = nextTarget(sys, run)
		truthy(second and second.TargetId ~= first.TargetId, "replaced")
		local _, reason = sys.targets:ApplyHit(a, first.TargetId, 1)
		eq(reason, "NotFound", "stale hit")
		_, reason = sys.targets:HandleShown(a, first.TargetId)
		eq(reason, "NotFound", "stale ack")
		eq(second.State, "AwaitingAck", "new target unchanged")
	end)

	it("drops hit requests over the per-tick limit", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		for _ = 1, 10 do
			sys.targets:HandleHitRequest(a, 999)
		end
		local _, reason = sys.targets:HandleHitRequest(a, 999)
		eq(reason, "RateLimited", "11th request")
		_, reason = sys.targets:HandleHitRequest(a, -1)
		eq(reason, "RateLimited", "still limited")
		sys.time.advance(0.25)
		_, reason = sys.targets:HandleHitRequest(a, 1.5)
		eq(reason, "InvalidRequest", "malformed id")
	end)
end)

describe("Scoring", function()
	it("destroying with 3 s left scores 100 + 50 * 3", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local target = nextTarget(sys, run)
		truthy(sys.targets:HandleShown(a, target.TargetId), "ack")
		sys.step(2.5)
		local ok, outcome = sys.targets:ApplyHit(a, target.TargetId, 100)
		eq(outcome, "Destroyed", "destroyed")
		truthy(ok, "ok")
		near(run.Score, 250, "score")
	end)

	it("the hidden grace keeps the bonus at the full TargetTime", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local target = nextTarget(sys, run)
		reveal(sys, a, target)
		sys.targets:ApplyHit(a, target.TargetId, 100)
		near(run.Score, 100 + 50 * 5, "full time")
	end)

	it("overkill credits only the remaining health", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local target = nextTarget(sys, run)
		reveal(sys, a, target)
		sys.targets:ApplyHit(a, target.TargetId, 90)
		eq(run.Score, 90, "base points")
		sys.targets:ApplyHit(a, target.TargetId, 100)
		near(run.Score, 100 + 50 * 5, "10 credited, not 100")
	end)

	it("a timed-out target keeps its base points and ends the run once", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local target = nextTarget(sys, run)
		reveal(sys, a, target)
		sys.targets:ApplyHit(a, target.TargetId, 99)
		sys.step(5.5)
		eq(#sys.settlements, 1, "settled")
		eq(sys.settlements[1].Reason, "Timeout", "reason")
		eq(sys.settlements[1].Run.Score, 99, "99 points")
		local _, reason = sys.targets:ApplyHit(a, target.TargetId, 1)
		eq(reason, "NotFound", "late hit")
		sys.step(1)
		eq(#sys.settlements, 1, "settled once")
	end)
end)

describe("Progression", function()
	it("health doubles and the radius grows for spawns 2..10, then stays fixed", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local radii, healths = {}, {}
		for index = 1, 11 do
			local target = nextTarget(sys, run)
			truthy(target, `target {index} placed`)
			eq(run.SpawnIndex, index, "spawn index")
			radii[index] = run.Radius
			healths[index] = target.MaxHealth
			reveal(sys, a, target)
			sys.targets:ApplyHit(a, target.TargetId, 1e9)
		end
		eq(radii[1], 5, "#1")
		eq(radii[2], 10, "#2")
		eq(radii[10], 5 * 2 ^ 9, "#10")
		eq(radii[11], radii[10], "#11 keeps #10's radius")
		eq(healths[1], 100, "first health")
		eq(healths[2], 200, "previous max * scale")
		eq(healths[11], 100 * 2 ^ 10, "every destruction rolls")
	end)

	it("failed batches don't advance progression; five failed batches settle the run", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local first = nextTarget(sys, run)
		reveal(sys, a, first)
		sys.targets:ApplyHit(a, first.TargetId, 100)
		eq(run.Radius, 10, "rolled once on destruction")

		sys.world.noGround = true
		sys.world.raycasts = 0
		sys.step(0.15) -- batch 1
		sys.step(0.25) -- batch 2
		eq(sys.world.raycasts, 120, "two batches of 60")
		eq(run.Radius, 10, "radius unchanged by failures")
		eq(run.MaxHealth, 200, "health unchanged by failures")
		sys.step(0.75) -- batches 3..5
		eq(sys.world.raycasts, 300, "bounded at 5 x 60")
		eq(#sys.settlements, 1, "settled")
		eq(sys.settlements[1].Reason, "PlacementExhausted", "reason")
		near(sys.settlements[1].Run.Score, 350, "keeps the earned score")
		eq(run.SpawnIndex, 1, "no extra spawn counted")
	end)

	it("ends the run when health would exceed exact whole numbers", function()
		local sys = setup()
		redEntry(sys).Scale = { Min = 2 ^ 52, Max = 2 ^ 52 }
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local target = nextTarget(sys, run)
		reveal(sys, a, target)
		sys.targets:ApplyHit(a, target.TargetId, 100)
		eq(sys.settlements[1].Reason, "HealthLimit", "reason")
	end)
end)

describe("Rewards and cooldown", function()
	local function rewardSystem(pay)
		local configs = TestKit.Configs()
		configs.targetConfig.RewardBrackets = {
			{ MinScore = 50, Drops = { { Weight = 1, Name = "Low" } } },
			{ MinScore = 1000, Drops = { { Weight = 1, Name = "High" } } },
		}
		local sys = TestKit.TargetSystem({ configs = configs, pay = pay })
		sys.addZone("Meadow")
		return sys
	end

	it("pays the highest bracket reached once and starts the global cooldown", function()
		local paid = {}
		local sys = rewardSystem(function(player, drop)
			table.insert(paid, drop.Name)
			return true
		end)
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local target = nextTarget(sys, run)
		reveal(sys, a, target)
		sys.targets:ApplyHit(a, target.TargetId, 99)
		sys.step(5.5)
		eq(#paid, 1, "paid once")
		eq(paid[1], "Low", "bracket")
		local status = sys.targets:GetStatus(a)
		truthy(status.CooldownEndsAt > sys.time.t, "cooldown running")

		local starter = spawnStarter(sys, 10, 10)
		sys.step(0.15)
		local _, reason = sys.targets:ApplyHit(a, starter.TargetId, 1)
		eq(reason, "OnCooldown", "blocked")
		sys.step(30)
		local fresh = spawnStarter(sys, -10, -10)
		sys.step(0.15)
		truthy(sys.targets:ApplyHit(a, fresh.TargetId, 1), "allowed after the cooldown")
	end)

	it("no bracket reached and failed payment both leave no cooldown", function()
		local sys = rewardSystem(function()
			return false, "Broken"
		end)
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local target = nextTarget(sys, run)
		reveal(sys, a, target)
		sys.targets:ApplyHit(a, target.TargetId, 10)
		sys.step(5.5)
		eq(sys.targets:GetStatus(a).CooldownEndsAt, 0, "below the first bracket")

		run = startRun(sys, a, 10, 10)
		target = nextTarget(sys, run)
		reveal(sys, a, target)
		sys.targets:ApplyHit(a, target.TargetId, 99)
		sys.step(5.5)
		eq(sys.settlements[2].Paid, nil, "not paid")
		eq(sys.targets:GetStatus(a).CooldownEndsAt, 0, "no cooldown after a failed payment")
		local warned = false
		for _, message in sys.warnings do
			warned = warned or message:find("not paid (Broken)", 1, true) ~= nil
		end
		truthy(warned, "warned")
	end)

	it("a missing model before the first target settles with nothing", function()
		local sys = rewardSystem(function()
			return true
		end)
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		startRun(sys, a)
		sys.targetWorld.missing.Target = true
		sys.step(0.15)
		eq(sys.settlements[1].Reason, "ModelMissing", "reason")
		eq(sys.settlements[1].Paid, nil, "no reward")
		eq(sys.targets:GetStatus(a).CooldownEndsAt, 0, "no cooldown")
	end)
end)

describe("Target cleanup", function()
	it("departure removes the target at once, with no settlement", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local target = nextTarget(sys, run)
		sys.targets:RemovePlayer(a)
		truthy(target.Model.Destroyed, "model destroyed")
		eq(sys.targetRegistry:Get(target.TargetId), nil, "record gone")
		eq(sys.targetRegistry:GetRunOf(a.UserId), nil, "run gone")
		eq(#sys.settlements, 0, "nothing settled")
		sys.targets:RemovePlayer(a) -- idempotent
	end)

	it("death doesn't end the run; its timers keep running", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local target = nextTarget(sys, run)
		reveal(sys, a, target)
		sys.roots[a] = nil -- dead
		sys.step(2)
		truthy(sys.targetRegistry:GetRunOf(a.UserId), "run continues")
		local _, reason = sys.targets:ApplyHit(a, target.TargetId, 1)
		eq(reason, "NoCharacter", "can't hit while dead")
		sys.step(4)
		eq(sys.settlements[1].Reason, "Timeout", "normal timeout")
	end)

	it("removing the zone settles its runs and clears its starters", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		nextTarget(sys, run)
		local starter = spawnStarter(sys, 10, 10)
		sys.zones:Unregister(sys.zonePart)
		eq(sys.settlements[1].Reason, "ZoneRemoved", "settled")
		truthy(starter.Model.Destroyed, "starter removed")
		eq(sys.targetRegistry:CountStarters("Meadow"), 0, "no starters")
	end)

	it("shutdown discards everything", function()
		local sys = setup()
		local a = sys.addPlayer("A", Vector3.new(0, 3, 0))
		local run = startRun(sys, a)
		local target = nextTarget(sys, run)
		local starter = spawnStarter(sys, 10, 10)
		sys.targets:Destroy()
		truthy(target.Model.Destroyed and starter.Model.Destroyed, "models destroyed")
		eq(#sys.targetRegistry:GetRuns(), 0, "no runs")
		local _, reason = sys.targets:ApplyHit(a, target.TargetId, 1)
		eq(reason, "NotFound", "late request")
	end)
end)

describe("Target presentation", function()
	local viewer = { UserId = 1, InRun = false, CooldownEndsAt = 0, Now = 100 }
	local Mode = TargetVisuals.Mode

	it("starters are normal, faded in a run, gray on cooldown", function()
		local starter = { Kind = "Starter", OwnerUserId = 0, Revealed = true }
		eq(TargetVisuals.GetMode(starter, viewer), Mode.Normal, "eligible")
		eq(TargetVisuals.GetMode(starter, { UserId = 1, InRun = true, CooldownEndsAt = 0, Now = 100 }), Mode.Faded, "in run")
		eq(TargetVisuals.GetMode(starter, { UserId = 1, InRun = false, CooldownEndsAt = 120, Now = 100 }), Mode.Gray, "cooldown")
		eq(TargetVisuals.GetMode(starter, { UserId = 1, InRun = false, CooldownEndsAt = 90, Now = 100 }), Mode.Normal, "expired cooldown")
	end)

	it("targets face whichever living player is closest", function()
		local roots = { [1] = Vector3.new(10, 3, 0), [2] = Vector3.new(0, 3, 4) }
		eq(TargetVisuals.GetFacePosition(Vector3.zero, roots), roots[2], "closest")
		eq(TargetVisuals.GetFacePosition(Vector3.new(9, 0, 0), roots), roots[1], "changes as positions change")
		eq(TargetVisuals.GetFacePosition(Vector3.zero, {}), nil, "nobody to face")
	end)

	it("facing turns about the vertical axis only", function()
		local pivot = CFrame.new(5, 2, 5)
		local facing = TargetVisuals.FacingCFrame(pivot, Vector3.new(5, 40, 15)) -- far above and in front
		near(facing.Position.X, 5, "x kept")
		near(facing.Position.Y, 2, "height kept")
		near(facing.LookVector.Y, 0, "no tilt")
		near(facing.LookVector.Z, 1, "faces +Z")
		near(facing.UpVector.Y, 1, "upright")
		eq(TargetVisuals.FacingCFrame(pivot, Vector3.new(5, 10, 5)), nil, "directly above: keep facing")
	end)

	it("scoring targets: owner sees them, spectators only after the acknowledgment and faded", function()
		eq(TargetVisuals.GetMode({ Kind = "Scoring", OwnerUserId = 1, Revealed = false }, viewer), Mode.Owner, "owner")
		eq(TargetVisuals.GetMode({ Kind = "Scoring", OwnerUserId = 2, Revealed = false }, viewer), Mode.Hidden, "before ack")
		eq(TargetVisuals.GetMode({ Kind = "Scoring", OwnerUserId = 2, Revealed = true }, viewer), Mode.Faded, "after ack")
		falsy(TargetVisuals.IsClickable(Mode.Faded), "faded not clickable")
		falsy(TargetVisuals.IsClickable(Mode.Gray), "gray not clickable")
		truthy(TargetVisuals.IsClickable(Mode.Owner), "owner clickable")
	end)
end)
