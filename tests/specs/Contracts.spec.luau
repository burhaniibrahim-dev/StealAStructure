local TestKit = require("../TestKit")
local describe, it, eq, truthy, falsy = TestKit.describe, TestKit.it, TestKit.eq, TestKit.truthy, TestKit.falsy

local ConfigValidator = TestKit.ConfigValidator
local InventoryState = require("../../src/ReplicatedStorage/Shared/Features/Inventory/InventoryState")
local PlayerDataService = require("../../src/ServerScriptService/Features/Data/PlayerDataService")
local DataTemplate = require("../../src/ServerScriptService/Features/Data/DataTemplate")

local function shippedInputs()
	return {
		itemCatalog = require("../../src/ReplicatedStorage/Shared/Configs/ItemDefintions"),
		inventoryConfig = require("../../src/ReplicatedStorage/Shared/Configs/InventoryConfig"),
		pickupConfig = require("../../src/ServerScriptService/Configs/Eggs/PickupConfig"),
		placementConfig = require("../../src/ServerScriptService/Configs/Eggs/PlacementConfig"),
		spawnerConfig = require("../../src/ServerScriptService/Configs/Zones/SpawnerConfig"),
		zoneIdConfig = require("../../src/ServerScriptService/Configs/Zones/IdConfig"),
		tutorialConfig = require("../../src/ServerScriptService/Configs/TutorialConfig"),
		debugConfig = require("../../src/ServerScriptService/Configs/DebugConfig"),
		targetConfig = require("../../src/ServerScriptService/Configs/Targets/TargetConfig"),
		hasTemplate = function()
			return true
		end,
	}
end

local function fixtureInputs()
	local inputs = TestKit.Configs()
	inputs.itemCatalog = TestKit.ItemCatalog()
	return inputs
end

describe("Config validation", function()
	it("accepts the shipped configs", function()
		local ok, errors = ConfigValidator.validate(shippedInputs())
		truthy(ok, table.concat(errors, "; "))
	end)

	it("the catalog is pure: every top-level key is an egg with a model", function()
		local inputs = shippedInputs()
		for itemTypeId, definition in inputs.itemCatalog do
			eq(type(definition), "table", `{itemTypeId} is an egg entry`)
			eq(type(definition.ModelName), "string", `{itemTypeId}.ModelName`)
		end
		eq(inputs.itemCatalog.MAX_STACK, nil, "MAX_STACK lives in InventoryConfig")
		eq(ConfigValidator.findVisualFallback(inputs.itemCatalog), "Common", "configured visual fallback")
	end)

	it("reports bad values by file and field", function()
		local inputs = fixtureInputs()
		inputs.zoneIdConfig.Zones.Default.Eggs[1].Weight = 0
		inputs.zoneIdConfig.Zones.Default.Eggs[2].ItemTypeId = "GhostEgg"
		inputs.zoneIdConfig.Zones.Default.Eggs[1].Amount = { Min = 1, Max = 500 }
		inputs.zoneIdConfig.FallbackZoneProfile = "Missing"
		inputs.spawnerConfig.SpawnInterval = { Min = 5, Max = 1 }
		inputs.spawnerConfig.PlacementAttempts = 0
		inputs.spawnerConfig.BasePickups = 10 -- above MaxPickups
		inputs.pickupConfig.CollectRadius = 1 -- below PickupRadius
		local ok, errors = ConfigValidator.validate(inputs)
		falsy(ok, "valid")
		local text = table.concat(errors, "\n")
		truthy(text:find("IdConfig.Zones.Default.Eggs[1].Weight must be > 0", 1, true), "weight")
		truthy(text:find('"GhostEgg" is not in ItemDefintions', 1, true), "unknown item")
		truthy(text:find("Amount.Max must be <= InventoryConfig.MAX_STACK", 1, true), "amount within stack")
		truthy(text:find("IdConfig.FallbackZoneProfile", 1, true), "fallback")
		truthy(text:find("SpawnerConfig.SpawnInterval", 1, true), "range")
		truthy(text:find("SpawnerConfig.PlacementAttempts", 1, true), "attempts")
		truthy(text:find("BasePickups must be <= MaxPickups", 1, true), "target under the hard cap")
		truthy(text:find("PickupConfig.CollectRadius must be >= PickupRadius", 1, true), "trigger inside server range")
		falsy(pcall(ConfigValidator.assert, inputs), "assert raises")
	end)

	it("survives malformed tables without crashing", function()
		local inputs = fixtureInputs()
		inputs.zoneIdConfig.Zones = { Default = "oops", Other = { Eggs = { "not an entry" } } }
		inputs.spawnerConfig = nil
		inputs.itemCatalog.IceEgg = 5
		local ok, errors = ConfigValidator.validate(inputs)
		falsy(ok, "valid")
		local text = table.concat(errors, "\n")
		truthy(text:find("IdConfig.Zones.Default must be a table", 1, true), "profile type")
		truthy(text:find("IdConfig.Zones.Other.Eggs[1] must be a table", 1, true), "entry type")
		truthy(text:find("SpawnerConfig must be a table", 1, true), "missing file")
		truthy(text:find("ItemDefintions.IceEgg must be a table", 1, true), "catalog entry type")
	end)

	it("a missing template is a startup error with the exact wording", function()
		local inputs = fixtureInputs()
		inputs.hasTemplate = function(modelName)
			return modelName ~= "IceEgg"
		end
		local ok, errors = ConfigValidator.validate(inputs)
		falsy(ok, "valid")
		eq(errors[1], "MODEL OF IceEgg doesnt exist", "message")
	end)

	it("requires exactly one visual fallback egg", function()
		local inputs = fixtureInputs()
		inputs.itemCatalog.IceEgg.VisualFallback = true
		local _, errors = ConfigValidator.validate(inputs)
		truthy(table.concat(errors, "\n"):find("exactly one entry with VisualFallback", 1, true), "two fallbacks")
	end)

	it("does not validate removed mechanics", function()
		local inputs = fixtureInputs()
		inputs.pickupConfig.SweepRadius = nil
		inputs.spawnerConfig.PopulationCap = nil
		local ok, errors = ConfigValidator.validate(inputs)
		truthy(ok, table.concat(errors, "; "))
	end)
end)

describe("Profile template", function()
	it("seeds the saved tutorial flag from TutorialConfig without changing saved keys", function()
		local template = DataTemplate(false)
		eq(template.Tutorial.OrdinaryCollectionEnabled, false, "seeded")
		eq(type(template.Inventory), "table", "Inventory")
		eq(template.Milestones.FirstOrdinaryCollection, false, "Milestones kept")
	end)
end)

describe("Inventory revisions", function()
	it("server revisions increase per mutation", function()
		local sys = TestKit.System()
		local player = sys.addPlayer("A", Vector3.new())
		local revisions = {}
		sys.inventory.Changed:Connect(function(_, _, _, revision)
			table.insert(revisions, revision)
		end)
		sys.inventory:TryAdd(player, "SnowEgg", 2)
		sys.inventory:TryConsume(player, "SnowEgg", 1)
		eq(revisions[1], 1, "first")
		eq(revisions[2], 2, "second")
		eq(sys.inventory:GetSnapshot(player).Revision, 2, "snapshot revision")
		falsy(sys.inventory:TryConsume(player, "SnowEgg", 5), "overdraw")
		falsy(sys.inventory:TryAdd(player, "SnowEgg", 1.5), "fractional")
		falsy(sys.inventory:TryAdd(player, "GhostEgg", 1), "unknown")
	end)

	it("the client ignores stale updates", function()
		local state = InventoryState.new(100)
		truthy(state:ApplySnapshot({ Revision = 3, MaxStack = 100, Counts = { SnowEgg = 10 } }), "snapshot")
		falsy(state:ApplyChange({ Revision = 2, ItemTypeId = "SnowEgg", Count = 4 }), "older change")
		falsy(state:ApplyChange({ Revision = 3, ItemTypeId = "SnowEgg", Count = 4 }), "same revision change")
		truthy(state:ApplyChange({ Revision = 4, ItemTypeId = "SnowEgg", Count = 100 }), "newer change")
		falsy(state:ApplySnapshot({ Revision = 1, MaxStack = 100, Counts = { SnowEgg = 0 } }), "older snapshot")
		eq(state:GetCount("SnowEgg"), 100, "count")
		truthy(state:IsFull("SnowEgg"), "full stack flagged")
	end)
end)

describe("Player data readiness", function()
	local function makeService(startSession)
		local kicks = {}
		local service = PlayerDataService.new({
			Signal = TestKit.Signal,
			startSession = startSession,
			isPresent = function(player)
				return player.Present
			end,
			kick = function(player, message)
				table.insert(kicks, { Player = player, Message = message })
			end,
			warn = function() end,
		})
		return service, kicks
	end

	it("fails closed with a rejoin message instead of a blank save", function()
		local service, kicks = makeService(function()
			error("DataStore unavailable")
		end)
		local player = TestKit.FakePlayer()
		local readyFired = false
		service.Ready:Connect(function()
			readyFired = true
		end)
		service:LoadAsync(player)
		falsy(service:IsActive(player), "active")
		eq(service:GetData(player), nil, "no fallback data")
		falsy(readyFired, "never ready")
		eq(#kicks, 1, "kicked")
		truthy(kicks[1].Message:find("rejoin"), "rejoin message")
	end)

	it("becomes active on load and releases cleanly", function()
		local ended = false
		local profile = {
			Data = { Inventory = {} },
			_active = true,
			OnSessionEnd = TestKit.Signal.new(),
		}
		function profile:IsActive()
			return self._active
		end
		function profile:EndSession()
			self._active = false
			ended = true
			self.OnSessionEnd:Fire()
		end
		local service, kicks = makeService(function()
			return profile
		end)
		local player = TestKit.FakePlayer()
		local released = 0
		service.Releasing:Connect(function()
			released += 1
		end)
		service:LoadAsync(player)
		truthy(service:IsActive(player), "active")
		player.Present = false
		service:Release(player)
		truthy(ended, "session ended")
		eq(released, 1, "released once")
		eq(#kicks, 0, "no kick for a normal leave")
		falsy(service:IsActive(player), "inactive after release")
	end)
end)
