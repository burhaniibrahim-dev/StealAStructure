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

function TestKit.FakeModels()
	local models = { created = 0, destroyed = 0, live = {} }
	function models.Create(record)
		models.created += 1
		models.live[record.PickupId] = true
		return function()
			models.destroyed += 1
			models.live[record.PickupId] = nil
		end
	end
	return models
end

-- Full system ------------------------------------------------------------------

local Signal = require("../src/ServerScriptService/Util/Signal")
local ZoneDetection = require("../src/ServerScriptService/Features/Zones/ZoneDetection")
local ZoneService = require("../src/ServerScriptService/Features/Zones/ZoneService")
local ZoneSpawner = require("../src/ServerScriptService/Features/Zones/ZoneSpawner")
local SpawnTrackRegistry = require("../src/ServerScriptService/Features/Zones/SpawnTrackRegistry")
local ItemRegistry = require("../src/ServerScriptService/Features/Items/ItemRegistry")
local ItemService = require("../src/ServerScriptService/Features/Items/ItemService")
local PickupPlacement = require("../src/ServerScriptService/Features/Items/PickupPlacement")
local PickupAnalytics = require("../src/ServerScriptService/Features/Items/PickupAnalytics")
local ExclusionProviders = require("../src/ServerScriptService/Features/Items/ExclusionProviders")
local InventoryService = require("../src/ServerScriptService/Features/Inventory/InventoryService")

TestKit.Signal = Signal
TestKit.ZoneDetection = ZoneDetection
TestKit.ZoneService = ZoneService
TestKit.ZoneSpawner = ZoneSpawner
TestKit.SpawnTrackRegistry = SpawnTrackRegistry
TestKit.ItemRegistry = ItemRegistry
TestKit.ItemService = ItemService
TestKit.ExclusionProviders = ExclusionProviders
TestKit.InventoryService = InventoryService

function TestKit.ItemDefinitions()
	return {
		MAX_STACK = 100,
		Items = {
			SnowEgg = { DisplayName = "Snow Egg", Order = 1 },
			IceEgg = { DisplayName = "Ice Egg", Order = 2 },
		},
	}
end

function TestKit.Config()
	return {
		PickupLifetime = 30,
		ServerMaxPickups = 50,
		PickupRadius = 3,
		SweepRadius = 5,
		CollectRadius = 8,
		ProximitySweepInterval = 0.25,
		InventoryFullCooldown = 2,
		Schedule = {
			TickInterval = 0.25,
			SpawnInterval = { Min = 1, Max = 5 },
			RatePerExtraPlayer = 0.5,
			MaxRateMultiplier = 3,
			PopulationCap = 4,
		},
		Placement = {
			MaxAttempts = 5,
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
		Zones = {
			Default = {
				BasePickups = 3,
				PickupsPerExtraPlayer = 2,
				MaxPickups = 8,
				Distribution = {
					{ ItemTypeId = "SnowEgg", Weight = 3, Amount = { Min = 1, Max = 1 } },
					{ ItemTypeId = "IceEgg", Weight = 1, Amount = { Min = 1, Max = 1 } },
				},
			},
		},
		FallbackZoneProfile = "Default",
		Tutorial = {
			DefaultOrdinaryCollectionEnabled = true,
			ReservedLifetime = 120,
			MaxReservedPerPlayer = 3,
			MaxReservedAmount = 25,
		},
	}
end

-- Builds the real services around fakes. options: config?, traps?, exclusions?, canAccess?
function TestKit.System(options)
	options = options or {}
	local sys = {}
	sys.config = options.config or TestKit.Config()
	sys.itemDefinitions = TestKit.ItemDefinitions()
	sys.time = TestKit.FakeTime()
	sys.rng = TestKit.FakeRandom(options.seed)
	sys.world = TestKit.FakeWorld()
	sys.models = TestKit.FakeModels()
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
	sys.registry = ItemRegistry.new()
	sys.inventory = InventoryService.new({ data = sys.data, itemDefinitions = sys.itemDefinitions, Signal = Signal })
	sys.analytics = PickupAnalytics.new({ data = sys.data, Signal = Signal })
	sys.placement = PickupPlacement.new({
		config = sys.config.Placement,
		detection = ZoneDetection,
		world = sys.world,
		registry = sys.registry,
		getAnchors = function(zoneId)
			return sys.zones:GetAnchors(zoneId)
		end,
		exclusions = options.exclusions or {},
		traps = options.traps or ExclusionProviders.NoTrapsProvider(),
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
	sys.items = ItemService.new({
		config = sys.config,
		itemDefinitions = sys.itemDefinitions,
		registry = sys.registry,
		placement = sys.placement,
		detection = ZoneDetection,
		zones = sys.zones,
		inventory = sys.inventory,
		data = sys.data,
		analytics = sys.analytics,
		tracks = sys.tracks,
		models = sys.models,
		scheduler = sys.time.scheduler,
		now = sys.time.now,
		rng = sys.rng,
		getPlayers = getPlayers,
		isPlayerPresent = function(player)
			return player.Present
		end,
		getRootPosition = getRootPosition,
		Signal = Signal,
		warn = warnSink,
	})
	sys.spawner = ZoneSpawner.new({
		config = sys.config,
		zones = sys.zones,
		items = sys.items,
		registry = sys.registry,
		rng = sys.rng,
	})
	sys.zones.ZoneRemoved:Connect(function(zoneId)
		sys.items:RemoveZonePickups(zoneId)
		sys.spawner:RemoveZone(zoneId)
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
		sys.items:OnPlayerRemoving(player)
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
	-- Spawn an ordinary pickup at an exact position by queuing the sampler's random values
	function sys.spawnAt(zoneId, x, z, itemTypeId, amount)
		local zone = sys.zones:GetZone(zoneId)
		local size = zone.Size
		local center = zone.CFrame.Position
		sys.rng:Push((x - center.X) / size.X + 0.5, (z - center.Z) / size.Z + 0.5)
		return sys.items:TrySpawnOrdinary(zoneId, itemTypeId or "SnowEgg", amount or 1, 1000)
	end
	function sys.setCount(player, itemTypeId, count)
		sys.data:GetData(player).Inventory[itemTypeId] = count
	end
	return sys
end

return TestKit
