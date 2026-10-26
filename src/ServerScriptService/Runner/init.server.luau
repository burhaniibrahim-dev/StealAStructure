-- Responsibility: The only server Script. Validates config, initializes every server system in a fixed order,
-- creates the shared instances they use, wires them together, and drives the shared ticks.
-- Construction details live in the child setup modules: Runner.Data, Runner.Zones, Runner.Eggs.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- Networker first so its remotes exist before clients wait on them
local Networker = require(ServerScriptService.Networker.Server)
local _Features = ServerScriptService.Features

local ItemDefinitions = require(ReplicatedStorage.Shared.Configs.Items.ItemDefinitions)
local ConfigValidator = require(ServerScriptService.Configs.ConfigValidator)
local PickupConfig = require(ServerScriptService.Configs.PickupConfig)
local Services = require(ServerScriptService.Services)
local Signal = require(ServerScriptService.Util.Signal)

local EggRegistry = require(_Features.Items.Eggs.EggRegistry)
local InventoryService = require(_Features.Inventory.InventoryService)
local ZoneService = require(_Features.Zones.ZoneService)

local Data = require(script.Data)
local Eggs = require(script.Eggs)
local Zones = require(script.Zones)

local ZONE_POLL_INTERVAL = 0.3

--============================================================================
-- Config

ConfigValidator.assert(PickupConfig, ItemDefinitions)

--============================================================================
-- Shared instances. Each is created once here and handed to every system that uses it

local eggRegistry = EggRegistry.new() -- egg management and zone spawning must count the same pickups
local rng = Random.new()

--============================================================================
-- Player data

local playerData = Data.Init({ config = PickupConfig })

-- Only players with an active profile count toward zone population (and therefore supply)
local function getActivePlayers()
	local active = {}
	for _, player in Players:GetPlayers() do
		if playerData:IsActive(player) then
			table.insert(active, player)
		end
	end
	return active
end

--============================================================================
-- Inventory

local inventory = InventoryService.new({
	data = playerData,
	itemDefinitions = ItemDefinitions,
	Signal = Signal,
})

--============================================================================
-- Zones (stage 1: the zone service, needed by eggs)

local zones = Zones.Init({ getActivePlayers = getActivePlayers })

--============================================================================
-- Eggs

local eggs = Eggs.Init({
	config = PickupConfig,
	itemDefinitions = ItemDefinitions,
	playerData = playerData,
	inventory = inventory,
	zones = zones,
	eggRegistry = eggRegistry,
	rng = rng,
	getActivePlayers = getActivePlayers,
})

--============================================================================
-- Zones (stage 2: the spawner, which needs eggs)

local spawner = Zones.StartSpawner({
	config = PickupConfig,
	zones = zones,
	eggs = eggs,
	eggRegistry = eggRegistry,
	rng = rng,
})

--============================================================================
-- Live services

Services.PlayerData = playerData
Services.Inventory = inventory
Services.Zones = zones
Services.Eggs = eggs

--============================================================================
-- Wiring

zones.ZoneRemoved:Connect(function(zoneId)
	eggs:RemoveZonePickups(zoneId)
	spawner:RemoveZone(zoneId)
end)

playerData.Ready:Connect(function(player)
	local snapshot = inventory:GetSnapshot(player)
	if snapshot then
		Networker.InventorySnapshot.Fire(player, snapshot)
	end
end)

playerData.Releasing:Connect(function(player)
	eggs:OnPlayerRemoving(player)
	zones:RemovePlayer(player)
	inventory:ClearSession(player)
end)

inventory.Changed:Connect(function(player, itemTypeId, count, revision)
	Networker.InventoryChanged.Fire(player, { Revision = revision, ItemTypeId = itemTypeId, Count = count })
end)

eggs.Collected:Connect(function(player, record)
	Networker.PickupCollected.Fire(player, {
		PickupId = record.PickupId,
		ItemTypeId = record.ItemTypeId,
		Amount = record.Amount,
		Position = record.Position,
	})
end)

eggs.InventoryFull:Connect(function(player, itemTypeId)
	Networker.InventoryFull.Fire(player, { ItemTypeId = itemTypeId })
end)

--============================================================================
-- Player lifecycle

Players.PlayerAdded:Connect(function(player)
	playerData:LoadAsync(player)
end)
for _, player in Players:GetPlayers() do
	task.spawn(playerData.LoadAsync, playerData, player)
end

Players.PlayerRemoving:Connect(function(player)
	-- Releasing (above) runs the same cleanup before the save ends. The repeat calls are idempotent and
	-- cover players whose profile never loaded
	playerData:Release(player)
	eggs:OnPlayerRemoving(player)
	zones:RemovePlayer(player)
end)

--============================================================================
-- Zone activation. Bound last so ZoneRemoved cleanup is already connected when tagged parts register

zones:BindCollectionService(CollectionService, workspace)

--============================================================================
-- Ticks. Every step is non-yielding, so one Heartbeat connection drives them all

local schedule = PickupConfig.Schedule
local zoneElapsed, spawnElapsed, sweepElapsed, debugElapsed = 0, 0, 0, 0

-- Debug only (PickupConfig.DebugSpawnLog): why is or isn't each zone spawning?
local function logSpawnDebug()
	local stats = spawner:TakeStats()
	local zoneList = zones:GetZones()
	if #zoneList == 0 then
		print(
			`[PickupDebug] No zones registered. Parts tagged {ZoneService.ZONE_TAG} need a string ZoneId attribute `
				.. "and must be in Workspace; see warnings above."
		)
		return
	end
	local lines = {}
	for _, zone in zoneList do
		local outcomes = {}
		for outcome, count in stats[zone.ZoneId] or {} do
			table.insert(outcomes, `{outcome}={count}`)
		end
		table.insert(
			lines,
			`  {zone.ZoneId}: players={zones:GetPopulation(zone.ZoneId)} pickups={eggRegistry:CountZone(zone.ZoneId)} `
				.. `outcomes=[{table.concat(outcomes, ", ")}]`
		)
	end
	local unloaded = #Players:GetPlayers() - #getActivePlayers()
	print(`[PickupDebug] {#zoneList} zone(s), {unloaded} player(s) without a loaded profile\n{table.concat(lines, "\n")}`)
end

local heartbeat = RunService.Heartbeat:Connect(function(deltaTime)
	zoneElapsed += deltaTime
	spawnElapsed += deltaTime
	sweepElapsed += deltaTime
	debugElapsed += deltaTime

	if PickupConfig.DebugSpawnLog and debugElapsed >= PickupConfig.DebugLogInterval then
		debugElapsed = 0
		logSpawnDebug()
	end

	if zoneElapsed >= ZONE_POLL_INTERVAL then
		zoneElapsed = 0
		zones:Poll()
	end
	if spawnElapsed >= schedule.TickInterval then
		spawnElapsed = 0
		eggs:ExpireDue()
		spawner:Step(time())
	end
	if sweepElapsed >= PickupConfig.ProximitySweepInterval then
		sweepElapsed = 0
		eggs:SweepProximity()
	end
end)

--============================================================================
-- Shutdown

game:BindToClose(function()
	heartbeat:Disconnect()
	spawner:Destroy()
	eggs:Destroy()
	zones:Destroy()
end)
