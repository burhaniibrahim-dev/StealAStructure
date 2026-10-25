local TestKit = require("../TestKit")
local describe, it, eq, truthy, falsy = TestKit.describe, TestKit.it, TestKit.eq, TestKit.truthy, TestKit.falsy

local ConfigValidator = require("../../src/ServerScriptService/Configs/ConfigValidator")
local PickupConfig = require("../../src/ServerScriptService/Configs/PickupConfig")
local ItemDefinitions = require("../../src/ReplicatedStorage/Shared/Configs/Items/ItemDefinitions")
local InventoryState = require("../../src/ReplicatedStorage/Shared/Inventory/InventoryState")
local PlayerDataService = require("../../src/ServerScriptService/Features/Data/PlayerDataService")

describe("Config validation", function()
	it("accepts the shipped config", function()
		local ok, errors = ConfigValidator.validate(PickupConfig, ItemDefinitions)
		truthy(ok, table.concat(errors, "; "))
	end)

	it("rejects bad weights, unknown items, bad ranges, and a missing fallback", function()
		local config = TestKit.Config()
		config.Zones.Default.Distribution[1].Weight = 0
		config.Zones.Default.Distribution[2].ItemTypeId = "GhostEgg"
		config.Schedule.SpawnInterval = { Min = 5, Max = 1 }
		config.FallbackZoneProfile = "Missing"
		config.Placement.MaxAttempts = 0
		local ok, errors = ConfigValidator.validate(config, TestKit.ItemDefinitions())
		falsy(ok, "valid")
		local text = table.concat(errors, "\n")
		truthy(text:find("Weight must be > 0"), "weight")
		truthy(text:find("GhostEgg"), "unknown item")
		truthy(text:find("SpawnInterval"), "range")
		truthy(text:find("FallbackZoneProfile"), "fallback")
		truthy(text:find("MaxAttempts"), "attempts")
		local raised = pcall(ConfigValidator.assert, config, TestKit.ItemDefinitions())
		falsy(raised, "assert raises")
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
