-- Responsibility: The only server Script. Validates config, builds every server feature in a fixed order,
-- wires them together, and drives the shared ticks. Features stay free of each other's internals.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- Networker first so its remotes exist before clients wait on them
local Networker = require(ServerScriptService.Networker.Server)
local _Features = ServerScriptService.Features

local ProfileStore = require(ServerScriptService.ServerPackages.ProfileStore)
local ItemDefinitions = require(ReplicatedStorage.Shared.Configs.Items.ItemDefinitions)
local ConfigValidator = require(ServerScriptService.Configs.ConfigValidator)
local PickupConfig = require(ServerScriptService.Configs.PickupConfig)
local Services = require(ServerScriptService.Services)
local Signal = require(ServerScriptService.Util.Signal)

local DataTemplate = require(_Features.Data.DataTemplate)
local PlayerDataService = require(_Features.Data.PlayerDataService)
local InventoryService = require(_Features.Inventory.InventoryService)
local ExclusionProviders = require(_Features.Items.ExclusionProviders)
local ItemRegistry = require(_Features.Items.ItemRegistry)
local ItemService = require(_Features.Items.ItemService)
local PickupAnalytics = require(_Features.Items.PickupAnalytics)
local PickupPlacement = require(_Features.Items.PickupPlacement)
local RobloxPickupWorld = require(_Features.Items.RobloxPickupWorld)
local SpawnTrackRegistry = require(_Features.Zones.SpawnTrackRegistry)
local ZoneDetection = require(_Features.Zones.ZoneDetection)
local ZoneService = require(_Features.Zones.ZoneService)
local ZoneSpawner = require(_Features.Zones.ZoneSpawner)

local PROFILE_STORE_NAME = "PlayerData_v1"
local ZONE_POLL_INTERVAL = 0.3
local EXCLUSION_TAG = "PickupExclusion"

--============================================================================
-- Config

ConfigValidator.assert(PickupConfig, ItemDefinitions)

--============================================================================
-- Player data

local profileStore = ProfileStore.New(PROFILE_STORE_NAME, DataTemplate(PickupConfig))

local playerData = PlayerDataService.new({
	Signal = Signal,
	isPresent = RobloxPickupWorld.isPlayerPresent,
	kick = function(player, message)
		player:Kick(message)
	end,
	startSession = function(player)
		local profile = profileStore:StartSessionAsync(`Player_{player.UserId}`, {
			Cancel = function()
				return player.Parent ~= Players
			end,
		})
		if profile then
			profile:AddUserId(player.UserId)
			profile:Reconcile()
		end
		return profile
	end,
})

local inventory = InventoryService.new({
	data = playerData,
	itemDefinitions = ItemDefinitions,
	Signal = Signal,
})

--============================================================================
-- Zones

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

local zones = ZoneService.new({
	Signal = Signal,
	Detection = ZoneDetection,
	getPlayers = getActivePlayers,
	getRootPosition = RobloxPickupWorld.getRootPosition,
})

--============================================================================
-- Pickups

local pickupFolder = Instance.new("Folder")
pickupFolder.Name = "Pickups"
pickupFolder.Parent = workspace

local traps = ExclusionProviders.NoTrapsProvider()
if traps.IsPlaceholder then
	warn("[Pickups] Trap exclusion uses NoTrapsProvider: no trap system exists yet, so trap avoidance is inactive.")
end

local registry = ItemRegistry.new()
local rng = Random.new()

local placement = PickupPlacement.new({
	config = PickupConfig.Placement,
	detection = ZoneDetection,
	registry = registry,
	world = RobloxPickupWorld.newWorld({
		workspace = workspace,
		pickupFolder = pickupFolder,
		zoneTag = ZoneService.ZONE_TAG,
	}),
	getAnchors = function(zoneId)
		return zones:GetAnchors(zoneId)
	end,
	exclusions = {
		ExclusionProviders.TaggedProvider("Structures and interaction points", CollectionService, EXCLUSION_TAG, workspace),
	},
	traps = traps,
})

local analytics = PickupAnalytics.new({ data = playerData, Signal = Signal })

local items -- assigned below; the model factory's touch handler needs it
local assets = ReplicatedStorage:FindFirstChild("Assets")

items = ItemService.new({
	config = PickupConfig,
	itemDefinitions = ItemDefinitions,
	registry = registry,
	placement = placement,
	detection = ZoneDetection,
	zones = zones,
	inventory = inventory,
	data = playerData,
	analytics = analytics,
	tracks = SpawnTrackRegistry.new({ spawn = task.spawn, cancel = task.cancel }),
	models = RobloxPickupWorld.newModelFactory({
		folder = pickupFolder,
		itemDefinitions = ItemDefinitions,
		templates = assets and assets:FindFirstChild("Pickups"),
		pickupRadius = PickupConfig.PickupRadius,
		onTouched = function(pickupId, player)
			items:HandleTouch(pickupId, player)
		end,
	}),
	scheduler = { Delay = task.delay, Cancel = task.cancel },
	now = time, -- elapsed game time; matches task.delay
	rng = rng,
	getPlayers = getActivePlayers,
	isPlayerPresent = RobloxPickupWorld.isPlayerPresent,
	getRootPosition = RobloxPickupWorld.getRootPosition,
	Signal = Signal,
})

local spawner = ZoneSpawner.new({
	config = PickupConfig,
	zones = zones,
	items = items,
	registry = registry,
	rng = rng,
})

Services.PlayerData = playerData
Services.Inventory = inventory
Services.Zones = zones
Services.Items = items
Services.Analytics = analytics

--============================================================================
-- Wiring

zones.ZoneRemoved:Connect(function(zoneId)
	items:RemoveZonePickups(zoneId)
	spawner:RemoveZone(zoneId)
end)

playerData.Ready:Connect(function(player)
	local snapshot = inventory:GetSnapshot(player)
	if snapshot then
		Networker.InventorySnapshot.Fire(player, snapshot)
	end
end)

playerData.Releasing:Connect(function(player)
	items:OnPlayerRemoving(player)
	zones:RemovePlayer(player)
	inventory:ClearSession(player)
end)

inventory.Changed:Connect(function(player, itemTypeId, count, revision)
	Networker.InventoryChanged.Fire(player, { Revision = revision, ItemTypeId = itemTypeId, Count = count })
end)

items.Collected:Connect(function(player, record)
	Networker.PickupCollected.Fire(player, {
		PickupId = record.PickupId,
		ItemTypeId = record.ItemTypeId,
		Amount = record.Amount,
		Position = record.Position,
	})
end)

items.InventoryFull:Connect(function(player, itemTypeId)
	Networker.InventoryFull.Fire(player, { ItemTypeId = itemTypeId })
end)

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
	items:OnPlayerRemoving(player)
	zones:RemovePlayer(player)
end)

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
			`  {zone.ZoneId}: players={zones:GetPopulation(zone.ZoneId)} pickups={registry:CountZone(zone.ZoneId)} `
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
		items:ExpireDue()
		spawner:Step(time())
	end
	if sweepElapsed >= PickupConfig.ProximitySweepInterval then
		sweepElapsed = 0
		items:SweepProximity()
	end
end)

game:BindToClose(function()
	heartbeat:Disconnect()
	spawner:Destroy()
	items:Destroy()
	zones:Destroy()
end)
