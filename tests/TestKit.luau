-- Responsibility: Tiny deterministic test framework plus fakes for the pickup system.
-- Real modules are wired with an injected clock, scheduler, RNG, world, and player data.

local roblox = require("@lune/roblox")

-- Pure modules use Roblox datatypes as globals, exactly as in game
Vector3 = roblox.Vector3
CFrame = roblox.CFrame
Color3 = roblox.Color3

local TestKit = {}

-- Framework ---------------------------------------------------------------------

local results = { passed = 0, failed = 0, failures = {} }
local currentGroup = ""

function TestKit.describe(name, body)
	currentGroup = name
	body()
	currentGroup = ""
end

function TestKit.it(name, body)
	local fullName = `{currentGroup} > {name}`
	local ok, err = pcall(body)
	if ok then
		results.passed += 1
		print(`  ok    {fullName}`)
	else
		results.failed += 1
		table.insert(results.failures, `{fullName}\n        {err}`)
		print(`  FAIL  {fullName}\n        {err}`)
	end
end

local function fmt(value)
	return if type(value) == "string" then `"{value}"` else tostring(value)
end

function TestKit.eq(actual, expected, label)
	if actual ~= expected then
		error(`{label or "value"}: expected {fmt(expected)}, got {fmt(actual)}`, 2)
	end
end

function TestKit.truthy(value, label)
	if not value then
		error(`{label or "value"}: expected truthy, got {fmt(value)}`, 2)
	end
end

function TestKit.falsy(value, label)
	if value then
		error(`{label or "value"}: expected falsy, got {fmt(value)}`, 2)
	end
end

function TestKit.results()
	return results
end

-- Fakes -------------------------------------------------------------------------

-- Deterministic Random replacement. Queue exact values with :Push, otherwise an LCG
function TestKit.FakeRandom(seed)
	local rng = { _state = seed or 12345, _queue = {} }
	local function nextUnit()
		if #rng._queue > 0 then
			return table.remove(rng._queue, 1)
		end
		rng._state = (rng._state * 1103515245 + 12345) % 2147483648
		return rng._state / 2147483648
	end
	-- Queue raw unit values in [0, 1)
	function rng:Push(...)
		for _, value in { ... } do
			table.insert(self._queue, value)
		end
	end
	function rng:NextNumber(min, max)
		local unit = nextUnit()
		if min == nil then
			return unit
		end
		return min + (max - min) * unit
	end
	function rng:NextInteger(min, max)
		return math.min(min + math.floor(nextUnit() * (max - min + 1)), max)
	end
	return rng
end

-- Manual clock + scheduler. Advance runs due callbacks in time order
function TestKit.FakeTime()
	local time = { t = 0, _tasks = {}, _nextHandle = 0 }
	function time.now()
		return time.t
	end
	time.scheduler = {
		Delay = function(seconds, fn)
			time._nextHandle += 1
			local handle = { Id = time._nextHandle, At = time.t + seconds, Fn = fn, Cancelled = false }
			table.insert(time._tasks, handle)
			return handle
		end,
		Cancel = function(handle)
			handle.Cancelled = true
		end,
	}
	function time.advance(seconds)
		local target = time.t + seconds
		while true do
			table.sort(time._tasks, function(a, b)
				return if a.At == b.At then a.Id < b.Id else a.At < b.At
			end)
			local due = time._tasks[1]
			if not due or due.At > target then
				break
			end
			table.remove(time._tasks, 1)
			time.t = due.At
			if not due.Cancelled then
				due.Fn()
			end
		end
		time.t = target
	end
	function time.pendingCount()
		local count = 0
		for _, handle in time._tasks do
			if not handle.Cancelled then
				count += 1
			end
		end
		return count
	end
	return time
end

local nextUserId = 1000
function TestKit.FakePlayer(name)
	nextUserId += 1
	return { Name = name or `Player{nextUserId}`, UserId = nextUserId, Present = true }
end

-- PlayerDataService contract
function TestKit.FakeData(template)
	local data = { _profiles = {} }
	function data:Load(player, overrides)
		local profile = {
			Inventory = {},
			Tutorial = { OrdinaryCollectionEnabled = true },
			Milestones = { FirstScriptedCollection = false, FirstOrdinaryCollection = false },
		}
		for key, value in overrides or template or {} do
			profile[key] = value
		end
		self._profiles[player] = profile
		return profile
	end
	function data:Unload(player)
		self._profiles[player] = nil
	end
	function data:IsActive(player)
		return self._profiles[player] ~= nil
	end
	function data:GetData(player)
		return self._profiles[player]
	end
	return data
end

-- Zone part: Block by default, centred on `position` (ground level) with authored attributes
function TestKit.FakeZonePart(attributes, options)
	options = options or {}
	local part = {
		ClassName = options.ClassName or "Part",
		Shape = { Name = options.Shape or "Block" },
		CFrame = options.CFrame or CFrame.new(options.Position or Vector3.new(0, 5, 0)),
		Size = options.Size or Vector3.new(40, 10, 40),
		_attributes = attributes or {},
	}
	function part:IsA(className)
		if className == "BasePart" then
			return self.ClassName == "Part" or self.ClassName == "MeshPart"
		end
		return className == self.ClassName
	end
	function part:GetAttribute(name)
		return self._attributes[name]
	end
	function part:GetFullName()
		return `Workspace.{self._attributes.ZoneId or "Zone"}`
	end
	return part
end

-- Flat ground at y = groundY everywhere unless overridden per test
function TestKit.FakeWorld()
	local world = {
		groundY = 0,
		material = "Grass",
		normal = Vector3.new(0, 1, 0),
		blocked = false,
		noGround = false,
		characters = {},
		obstructed = function()
			return false
		end,
		raycasts = 0,
	}
	function world:Raycast(origin, direction)
		self.raycasts += 1
		if self.noGround or origin.Y < self.groundY or origin.Y + direction.Y > self.groundY then
			return nil
		end
		return {
			Position = Vector3.new(origin.X, self.groundY, origin.Z),
			Normal = self.normal,
			Distance = origin.Y - self.groundY,
			Material = self.material,
			Blocked = self.blocked,
			Instance = "Ground",
		}
	end
	function world:GetCharacterPositions()
		return self.characters
	end
	function world:IsSpaceBlocked(position, radius, ignore)
		return self.obstructed(position, radius, ignore)
	end
	return world
end

-- Template lookup for egg models. Every model exists unless named in `missing`
function TestKit.FakeTemplates()
	local templates = { missing = {}, lookups = 0 }
	function templates.Has(modelName)
		templates.lookups += 1
		return not templates.missing[modelName]
	end
	return templates
end

-- Full system ------------------------------------------------------------------

local Signal = require("../src/ServerScriptService/Features/Util/Signal")
local ZoneDetection = require("../src/ServerScriptService/Features/Zones/ZoneDetection")
local ZoneService = require("../src/ServerScriptService/Features/Zones/ZoneService")
local ZoneSpawner = require("../src/ServerScriptService/Features/Zones/ZoneSpawner")
local SpawnTrackRegistry = require("../src/ServerScriptService/Features/Zones/SpawnTrackRegistry")
local EggRegistry = require("../src/ServerScriptService/Features/Items/Eggs/EggRegistry")
local EggService = require("../src/ServerScriptService/Features/Items/Eggs/EggService")
local PickupPlacement = require("../src/ServerScriptService/Features/Items/PickupPlacement")
local GroundProbe = require("../src/ServerScriptService/Features/Items/GroundProbe")
local ExclusionProviders = require("../src/ServerScriptService/Features/Items/ExclusionProviders")
local InventoryService = require("../src/ServerScriptService/Features/Inventory/InventoryService")
local ConfigValidator = require("../src/ServerScriptService/Features/Util/ConfigValidator")
local TargetRegistry = require("../src/ServerScriptService/Features/Targets/TargetRegistry")
local TargetPlacement = require("../src/ServerScriptService/Features/Targets/TargetPlacement")
local TargetService = require("../src/ServerScriptService/Features/Targets/TargetService")
local TargetSpawner = require("../src/ServerScriptService/Features/Targets/TargetSpawner")
local TargetRewards = require("../src/ServerScriptService/Features/Targets/TargetRewards")

TestKit.Signal = Signal
TestKit.ZoneDetection = ZoneDetection
TestKit.ZoneService = ZoneService
TestKit.ZoneSpawner = ZoneSpawner
TestKit.SpawnTrackRegistry = SpawnTrackRegistry
TestKit.EggRegistry = EggRegistry
TestKit.EggService = EggService
TestKit.ExclusionProviders = ExclusionProviders
TestKit.InventoryService = InventoryService
TestKit.ConfigValidator = ConfigValidator
TestKit.TargetRegistry = TargetRegistry
TestKit.TargetPlacement = TargetPlacement
TestKit.TargetService = TargetService
TestKit.TargetSpawner = TargetSpawner
TestKit.TargetRewards = TargetRewards

function TestKit.ItemCatalog()
	return {
		SnowEgg = { DisplayName = "Snow Egg", ModelName = "SnowEgg", Order = 1, VisualFallback = true },
		IceEgg = { DisplayName = "Ice Egg", ModelName = "IceEgg", Order = 2 },
	}
end

-- One fixture per config file, shaped exactly like the shipped files
function TestKit.Configs()
	return {
		inventoryConfig = { MAX_STACK = 100 },
		pickupConfig = {
			PickupLifetime = 30,
			PickupRadius = 3,
			CollectRadius = 8,
			CollectRequestsPerTick = 20,
			InventoryFullCooldown = 2,
		},
		placementConfig = {
			RaycastHeight = 40,
			RaycastDepth = 200,
			AnchorRaycastHeight = 3,
			SurfaceOffset = 1,
			MaxSlopeDegrees = 35,
			ForbiddenMaterials = { "Water" },
			PickupClearance = 4,
			CharacterClearance = 3,
			ObstructionRadius = 1,
			ExclusionPadding = 3,
			TrapPadding = 4,
		},
		spawnerConfig = {
			TickInterval = 0.25,
			SpawnInterval = { Min = 1, Max = 5 },
			SpawnIntervalCurve = 0.9,
			FirstSpawnDelay = 0.5,
			ReentryCreditMultiplier = 5,
			PlacementAttempts = 5,
			BasePickups = 3,
			MaxPickups = 4,
			MaxPickupsPerPlayer = 6,
		},
		zoneIdConfig = {
			FallbackZoneProfile = "Default",
			Zones = {
				Default = {
					Eggs = {
						{ ItemTypeId = "SnowEgg", Weight = 3, Amount = { Min = 1, Max = 1 } },
						{ ItemTypeId = "IceEgg", Weight = 1, Amount = { Min = 1, Max = 1 } },
					},
					Targets = {
						{
							TargetTypeId = "Red",
							Weight = 1,
							Health = { Min = 100, Max = 100 },
							Scale = { Min = 2, Max = 2 },
							RadiusGrowth = { Min = 2, Max = 2 },
						},
						{ TargetTypeId = "Nothing", Weight = 1 },
					},
				},
			},
		},
		tutorialConfig = { DefaultOrdinaryCollectionEnabled = true },
		debugConfig = { DebugSpawnLog = false, DebugLogInterval = 5 },
		targetConfig = {
			StartersPerZone = 3,
			StarterLifetime = 5,
			TargetTime = 5,
			GraceTime = 0.5,
			AppearDuration = 0.1,
			DisappearDuration = 0.1,
			PlacementCandidates = 60,
			RunPlacementBatches = 5,
			InitialRadius = 5,
			RadiusGrowthSpawnLimit = 10,
			Clearance = 4,
			EggClearance = 6,
			SurfaceOffset = 0,
			RewardCooldown = 30,
			RewardBrackets = {},
			TestHitDamage = 1,
			HitRequestsPerTick = 10,
			HitRange = 150,
			Types = { Red = { ModelName = "Target" } },
		},
	}
end

-- Builds the real services around fakes. options: configs?, traps?, exclusions?, canAccess?, seed?
function TestKit.System(options)
	options = options or {}
	local sys = {}
	sys.configs = options.configs or TestKit.Configs()
	sys.itemCatalog = TestKit.ItemCatalog()
	sys.time = TestKit.FakeTime()
	sys.rng = TestKit.FakeRandom(options.seed)
	sys.world = TestKit.FakeWorld()
	sys.templates = TestKit.FakeTemplates()
	sys.data = TestKit.FakeData()
	sys.players = {}
	sys.roots = {} -- [player] = Vector3?
	sys.warnings = {}
	sys.threads = {}

	local function warnSink(message)
		table.insert(sys.warnings, message)
	end
	local function getPlayers()
		local list = {}
		for _, player in sys.players do
			if player.Present then
				table.insert(list, player)
			end
		end
		return list
	end
	local function getRootPosition(player)
		return sys.roots[player]
	end

	sys.zones = ZoneService.new({
		Signal = Signal,
		Detection = ZoneDetection,
		getPlayers = getPlayers,
		getRootPosition = getRootPosition,
		canAccess = options.canAccess,
		warn = warnSink,
	})
	sys.eggRegistry = EggRegistry.new()
	sys.inventory = InventoryService.new({
		data = sys.data,
		itemCatalog = sys.itemCatalog,
		maxStack = sys.configs.inventoryConfig.MAX_STACK,
		Signal = Signal,
	})
	sys.ground = GroundProbe.new({
		world = sys.world,
		maxSlopeDegrees = sys.configs.placementConfig.MaxSlopeDegrees,
		forbiddenMaterials = sys.configs.placementConfig.ForbiddenMaterials,
	})
	sys.placement = PickupPlacement.new({
		config = sys.configs.placementConfig,
		detection = ZoneDetection,
		world = sys.world,
		ground = sys.ground,
		registry = sys.eggRegistry,
		getAnchors = function(zoneId)
			return sys.zones:GetAnchors(zoneId)
		end,
		exclusions = options.exclusions or {},
		traps = options.traps,
	})
	sys.tracks = SpawnTrackRegistry.new({
		spawn = function(fn, ...)
			local thread = coroutine.create(fn)
			table.insert(sys.threads, thread)
			coroutine.resume(thread, ...)
			return thread
		end,
		cancel = function(thread)
			coroutine.close(thread)
		end,
		warn = warnSink,
	})
	sys.eggs = EggService.new({
		pickupConfig = sys.configs.pickupConfig,
		spawnerConfig = sys.configs.spawnerConfig,
		itemCatalog = sys.itemCatalog,
		maxStack = sys.configs.inventoryConfig.MAX_STACK,
		registry = sys.eggRegistry,
		placement = sys.placement,
		zones = sys.zones,
		inventory = sys.inventory,
		data = sys.data,
		tracks = sys.tracks,
		scheduler = sys.time.scheduler,
		now = sys.time.now,
		rng = sys.rng,
		isPlayerPresent = function(player)
			return player.Present
		end,
		getRootPosition = getRootPosition,
		Signal = Signal,
		warn = warnSink,
	})
	sys.spawner = ZoneSpawner.new({
		spawnerConfig = sys.configs.spawnerConfig,
		zoneConfig = sys.configs.zoneIdConfig,
		itemCatalog = sys.itemCatalog,
		fallbackItemTypeId = "SnowEgg",
		templates = sys.templates,
		zones = sys.zones,
		eggs = sys.eggs,
		eggRegistry = sys.eggRegistry,
		getPlayers = getPlayers,
		getRootPosition = getRootPosition,
		rng = sys.rng,
		warn = warnSink,
	})
	sys.zones.ZoneRemoved:Connect(function(zoneId)
		sys.eggs:RemoveZonePickups(zoneId)
		sys.spawner:RemoveZone(zoneId)
	end)

	-- Every Removed signal, in order: { Record, Reason }
	sys.removals = {}
	sys.eggs.Removed:Connect(function(record, reason)
		table.insert(sys.removals, { Record = record, Reason = reason })
	end)

	-- Helpers
	function sys.addPlayer(name, position, loaded)
		local player = TestKit.FakePlayer(name)
		table.insert(sys.players, player)
		sys.roots[player] = position
		if loaded ~= false then
			sys.data:Load(player)
		end
		return player
	end
	function sys.removePlayer(player)
		player.Present = false
		sys.eggs:OnPlayerRemoving(player)
		sys.spawner:RemovePlayer(player)
		sys.zones:RemovePlayer(player)
		sys.data:Unload(player)
	end
	function sys.addZone(zoneId, options2)
		local attributes = { ZoneId = zoneId }
		for key, value in (options2 and options2.attributes) or {} do
			attributes[key] = value
		end
		local part = TestKit.FakeZonePart(attributes, options2)
		return part, sys.zones:Register(part)
	end
	-- Queue the sampler's random values so the next random candidate lands at (x, z) in `zoneId`
	function sys.pushPosition(zoneId, x, z)
		local zone = sys.zones:GetZone(zoneId)
		local size = zone.Size
		local center = zone.CFrame.Position
		sys.rng:Push((x - center.X) / size.X + 0.5, (z - center.Z) / size.Z + 0.5)
	end
	-- Spawn an egg owned by `owner` at an exact position
	function sys.spawnAt(owner, zoneId, x, z, itemTypeId, amount)
		sys.pushPosition(zoneId, x, z)
		return sys.eggs:TrySpawn(owner, zoneId, itemTypeId or "SnowEgg", amount or 1)
	end
	-- Polls zones and steps the spawner on the shared tick from the current time until `seconds` later
	function sys.run(seconds)
		local tick = sys.configs.spawnerConfig.TickInterval
		local target = sys.time.t + seconds
		while sys.time.t <= target + 1e-9 do
			sys.zones:Poll()
			sys.spawner:Step(sys.time.t)
			sys.time.advance(tick)
		end
	end
	function sys.setCount(player, itemTypeId, count)
		sys.data:GetData(player).Inventory[itemTypeId] = count
	end
	return sys
end

-- Targets ------------------------------------------------------------------------

-- Server target models as plain tables. Every model exists unless named in `missing`
function TestKit.FakeTargetWorld()
	local world = { missing = {}, models = {} }
	function world:HasModel(modelName)
		return not self.missing[modelName]
	end
	function world:Create(record, modelName)
		local model = {
			ModelName = modelName,
			Destroyed = false,
			Attributes = {
				TargetId = record.TargetId,
				Kind = record.Kind,
				OwnerUserId = record.OwnerUserId or 0,
				State = "Live",
				Revealed = record.Kind == "Starter",
				MaxHealth = record.MaxHealth or 0,
				Health = record.Health or 0,
				Deadline = 0,
			},
		}
		table.insert(self.models, model)
		return model
	end
	function world:SetAttributes(model, attributes)
		if model then
			for name, value in attributes do
				model.Attributes[name] = value
			end
		end
	end
	function world:Destroy(model)
		if model then
			model.Destroyed = true
		end
	end
	return world
end

-- The egg system plus the real target services around fakes. options: TestKit.System options, plus pay?
function TestKit.TargetSystem(options)
	options = table.clone(options or {})
	options.configs = options.configs or TestKit.Configs()
	-- Egg placement keeps EggClearance from live targets, exactly as Runner.Eggs wires it
	local targetRegistry = TargetRegistry.new()
	local exclusions = table.clone(options.exclusions or {})
	table.insert(exclusions, ExclusionProviders.PointProvider("Targets", function()
		return targetRegistry:IterateTargets()
	end, options.configs.targetConfig.EggClearance))
	options.exclusions = exclusions

	local sys = TestKit.System(options)
	sys.targetConfig = sys.configs.targetConfig
	sys.targetWorld = TestKit.FakeTargetWorld()
	sys.targetRegistry = targetRegistry
	sys.targetPlacement = TargetPlacement.new({
		config = sys.targetConfig,
		placementConfig = sys.configs.placementConfig,
		ground = sys.ground,
		detection = ZoneDetection,
		getZones = function()
			return sys.zones:GetZones()
		end,
		world = sys.world,
		eggRegistry = sys.eggRegistry,
		targetRegistry = sys.targetRegistry,
	})
	sys.targets = TargetService.new({
		config = sys.targetConfig,
		batchInterval = sys.configs.spawnerConfig.TickInterval,
		registry = sys.targetRegistry,
		placement = sys.targetPlacement,
		world = sys.targetWorld,
		rewards = TargetRewards.new({ brackets = sys.targetConfig.RewardBrackets, rng = sys.rng, pay = options.pay }),
		zones = sys.zones,
		data = sys.data,
		isPlayerPresent = function(player)
			return player.Present
		end,
		getRootPosition = function(player)
			return sys.roots[player]
		end,
		now = sys.time.now,
		rng = sys.rng,
		Signal = Signal,
		warn = function(message)
			table.insert(sys.warnings, message)
		end,
	})
	sys.targetSpawner = TargetSpawner.new({
		config = sys.targetConfig,
		spawnerConfig = sys.configs.spawnerConfig,
		zoneConfig = sys.configs.zoneIdConfig,
		zones = sys.zones,
		targets = sys.targets,
		registry = sys.targetRegistry,
		rng = sys.rng,
	})
	sys.zones.ZoneRemoved:Connect(function(zoneId)
		sys.targets:RemoveZone(zoneId)
		sys.targetSpawner:RemoveZone(zoneId)
	end)

	-- Every Settled signal, in order: { Run, Reason, Paid }
	sys.settlements = {}
	sys.targets.Settled:Connect(function(run, reason, paid)
		table.insert(sys.settlements, { Run = run, Reason = reason, Paid = paid })
	end)

	-- Advances the clock in small steps, sweeping like the Heartbeat does
	function sys.step(seconds)
		local target = sys.time.t + seconds
		while sys.time.t < target - 1e-9 do
			sys.time.advance(math.min(0.05, target - sys.time.t))
			sys.targets:Sweep(sys.time.t)
		end
	end
	return sys
end

return TestKit
