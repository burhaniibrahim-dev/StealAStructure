-- Responsibility: The only server Script. Validates config, initializes every server system in a fixed order,
-- creates the shared instances they use, wires them together, and drives the shared ticks.
-- Construction details live in the child setup modules: Runner.Data, Runner.Zones, Runner.Eggs
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Networker = require(script.ServerNetwork)	--Networker first so its remotes exist before clients wait on them
local Features = ServerScriptService.Features --Houses all our logic

local Services = require(Features.Util.Services)
local Signal = require(Features.Util.Signal)
local ConfigValidator = require(Features.Util.ConfigValidator)
local RobloxPickupWorld = require(Features.Items.Eggs.RobloxPickupWorld)

local ServerConfigs = ServerScriptService.Configs
local SharedConfigs = ReplicatedStorage.Shared.Configs

local ItemDefinitions = require(SharedConfigs.ItemDefintions)
local InventoryConfig = require(SharedConfigs.InventoryConfig)
local PickupConfig = require(ServerConfigs.Eggs.PickupConfig)
local PlacementConfig = require(ServerConfigs.Eggs.PlacementConfig)
local SpawnerConfig = require(ServerConfigs.Zones.SpawnerConfig)
local ZoneIdConfig = require(ServerConfigs.Zones.IdConfig)
local TutorialConfig = require(ServerConfigs.TutorialConfig)
local DebugConfig = require(ServerConfigs.DebugConfig)
local TargetConfig = require(ServerConfigs.Targets.TargetConfig)

local ZONE_POLL_INTERVAL = 0.3

--============================================================================
-- Config. Nothing below runs if any config is invalid or an authored egg template is missing

local eggTemplates = RobloxPickupWorld.newTemplateLookup(ReplicatedStorage)

ConfigValidator.assert({
	itemCatalog = ItemDefinitions,
	inventoryConfig = InventoryConfig,
	pickupConfig = PickupConfig,
	placementConfig = PlacementConfig,
	spawnerConfig = SpawnerConfig,
	zoneIdConfig = ZoneIdConfig,
	tutorialConfig = TutorialConfig,
	debugConfig = DebugConfig,
	targetConfig = TargetConfig,
	hasTemplate = eggTemplates.Has,
})

--============================================================================
-- Shared instances. Each is created once here and handed to every system that uses it

local EggRegistry = require(Features.Items.Eggs.EggRegistry)
local eggRegistry = EggRegistry.new() -- egg management and spawning must count the same records
local rng = Random.new()

--============================================================================
-- Player data
local Data = require(script.Data)
local playerData = Data.Init({ defaultOrdinaryCollectionEnabled = TutorialConfig.DefaultOrdinaryCollectionEnabled })

-- Only players with an active profile get zone membership (and therefore eggs)
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

local InventoryService = require(Features.Inventory.InventoryService)
local inventory = InventoryService.new({
	data = playerData,
	itemCatalog = ItemDefinitions,
	maxStack = InventoryConfig.MAX_STACK,
	Signal = Signal,
})
--============================================================================
-- Zones (stage 1: the zone service, needed by eggs)
local Zones = require(script.Zones)
local zones = Zones.Init({ getActivePlayers = getActivePlayers })
--============================================================================
-- Target minigame. Built before eggs: egg placement keeps clear of live targets and ignores their models.
-- Its own clock: server time, shared with clients for countdowns. Never mixed with time()

local function serverNow()
	return workspace:GetServerTimeNow()
end

local TargetsSetup = require(script.Targets)
local targets, targetSpawner, targetRegistry, targetFolder = TargetsSetup.Init({
	targetConfig = TargetConfig,
	placementConfig = PlacementConfig,
	spawnerConfig = SpawnerConfig,
	zoneConfig = ZoneIdConfig,
	zones = zones,
	eggRegistry = eggRegistry,
	playerData = playerData,
	rng = rng,
	now = serverNow,
})
--============================================================================
-- Eggs
local Eggs = require(script.Eggs)
local eggs = Eggs.Init({
	pickupConfig = PickupConfig,
	placementConfig = PlacementConfig,
	spawnerConfig = SpawnerConfig,
	itemCatalog = ItemDefinitions,
	maxStack = InventoryConfig.MAX_STACK,
	playerData = playerData,
	inventory = inventory,
	zones = zones,
	eggRegistry = eggRegistry,
	rng = rng,
	targetRegistry = targetRegistry,
	targetFolder = targetFolder,
	targetClearance = TargetConfig.EggClearance,
})
--============================================================================
-- Zones (stage 2: the spawner, which needs eggs)

local spawner = Zones.StartSpawner({
	spawnConfig = SpawnerConfig,
	zoneConfig = ZoneIdConfig,
	itemCatalog = ItemDefinitions,
	fallbackItemTypeId = ConfigValidator.findVisualFallback(ItemDefinitions),
	templates = eggTemplates,
	zones = zones,
	eggs = eggs,
	eggRegistry = eggRegistry,
	getActivePlayers = getActivePlayers,
	rng = rng,
})
--============================================================================
-- Live services
Services.PlayerData = playerData
Services.Inventory = inventory
Services.Zones = zones
Services.Eggs = eggs
Services.Targets = targets

--============================================================================
-- Owner-only egg networking. A player gets nothing live until their client asks for the snapshot,
-- so the snapshot and the live events that follow it arrive in order on the same reliable channel

local eggReady = {} -- [Player] = true once the snapshot was sent
local WIRE_REASONS = { Collected = true, Expired = true, ZoneRemoved = true, Removed = true }

local function toEggPayload(record)
	return {
		PickupId = record.PickupId,
		ItemTypeId = record.ItemTypeId,
		Amount = record.Amount,
		ZoneId = record.ZoneId,
		Position = record.Position,
		RemainingLifetime = eggs:GetRemainingLifetime(record),
	}
end

local function readyOwner(record)
	local player = Players:GetPlayerByUserId(record.OwnerUserId)
	return if player and eggReady[player] then player else nil
end

Networker.RequestEggSnapshot.On(function(player)
	if eggReady[player] then
		return
	end
	eggReady[player] = true
	local payload = {}
	for _, record in eggRegistry:GetOwnedBy(player.UserId) do
		table.insert(payload, toEggPayload(record))
	end
	Networker.EggSnapshot.Fire(player, { TriggerRadius = PickupConfig.PickupRadius, Eggs = payload })
end)

Networker.CollectEgg.On(function(player, request)
	eggs:HandleCollectRequest(player, request.PickupId)
end)

eggs.Spawned:Connect(function(record)
	local player = readyOwner(record)
	if player then
		Networker.EggSpawned.Fire(player, toEggPayload(record))
	end
end)

eggs.Removed:Connect(function(record, reason)
	-- OwnerLeft / Shutdown: the owner is gone, nobody to tell
	local player = WIRE_REASONS[reason] and readyOwner(record)
	if player then
		Networker.EggRemoved.Fire(player, { PickupId = record.PickupId, Reason = reason })
	end
end)

--============================================================================
-- Target networking. Entities replicate as models; only the player's own status and their requests use Blink
Networker.HitTarget.On(function(player, request)
	targets:HandleHitRequest(player, request.TargetId)
end)

Networker.TargetShown.On(function(player, request)
	targets:HandleShown(player, request.TargetId)
end)

local function sendTargetStatus(player)
	if player.Parent == Players then
		Networker.TargetStatus.Fire(player, targets:GetStatus(player))
	end
end
targets.StatusChanged:Connect(sendTargetStatus)

targets.Settled:Connect(function(run, endReason, paidDrop)
	if DebugConfig.DebugSpawnLog then
		print(
			`[TargetDebug] {run.Player.Name} run {run.RunId} ended ({endReason}): score {run.Score}, `
				.. `{run.SpawnIndex} target(s), reward {if paidDrop then "paid" else "none"}`
		)
	end
end)

--============================================================================
-- Wiring
zones.ZoneRemoved:Connect(function(zoneId)
	eggs:RemoveZonePickups(zoneId)
	spawner:RemoveZone(zoneId)
	targets:RemoveZone(zoneId)
	targetSpawner:RemoveZone(zoneId)
end)

playerData.Ready:Connect(function(player)
	local snapshot = inventory:GetSnapshot(player)
	if snapshot then
		Networker.InventorySnapshot.Fire(player, snapshot)
	end
	sendTargetStatus(player)
end)

playerData.Releasing:Connect(function(player)
	targets:RemovePlayer(player)
	eggs:OnPlayerRemoving(player)
	spawner:RemovePlayer(player)
	zones:RemovePlayer(player)
	inventory:ClearSession(player)
end)

inventory.Changed:Connect(function(player, itemTypeId, count, revision)
	Networker.InventoryChanged.Fire(player, { Revision = revision, ItemTypeId = itemTypeId, Count = count })
end)

eggs.InventoryFull:Connect(function(player, itemTypeId)
	Networker.InventoryFull.Fire(player, { ItemTypeId = itemTypeId })
end)

--============================================================================
-- Player lifecycle

-- Death restarts the player's egg schedules; their existing eggs stay until collected or expired
local function watchCharacter(player, character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Once(function()
			spawner:ResetPlayer(player)
		end)
	end
end

local function onPlayerAdded(player)
	player.CharacterAdded:Connect(function(character)
		watchCharacter(player, character)
	end)
	if player.Character then
		task.spawn(watchCharacter, player, player.Character)
	end
	playerData:LoadAsync(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	-- Releasing (above) runs the same cleanup before the save ends. The repeat calls are idempotent and
	-- cover players whose profile never loaded
	playerData:Release(player)
	targets:RemovePlayer(player)
	eggs:OnPlayerRemoving(player)
	spawner:RemovePlayer(player)
	zones:RemovePlayer(player)
	eggReady[player] = nil
end)

--============================================================================
-- Zone activation. Bound last so ZoneRemoved cleanup is already connected when tagged parts register
zones:BindCollectionService(CollectionService, workspace)

--============================================================================
-- Debug (DebugConfig.DebugSpawnLog): per player, where are they and why are or aren't their eggs spawning?
local function logEggDebug()
	local stats = spawner:TakeStats()
	local lines = {}
	for _, player in Players:GetPlayers() do
		local userId = player.UserId
		local zoneId = zones:GetZoneOf(player)
		local outcomes = {}
		for outcome, count in stats[userId] or {} do
			table.insert(outcomes, `{outcome}={count}`)
		end
		table.insert(
			lines,
			`  {player.Name}: active={playerData:IsActive(player)} zone={zoneId or "none"} `
				.. `eggs={eggRegistry:CountOwner(userId)} inZone={if zoneId then eggRegistry:CountOwnerZone(userId, zoneId) else 0} `
				.. `outcomes=[{table.concat(outcomes, ", ")}]`
		)
	end
	print(`[EggDebug] {#zones:GetZones()} zone(s), {#lines} player(s)\n{table.concat(lines, "\n")}`)
end

--============================================================================
-- Ticks. Every step is non-yielding, so one Heartbeat connection drives them all
local zoneElapsed, spawnElapsed, debugElapsed = 0, 0, 0

local heartbeat = RunService.Heartbeat:Connect(function(deltaTime)
	zoneElapsed += deltaTime
	spawnElapsed += deltaTime
	debugElapsed += deltaTime

	if DebugConfig.DebugSpawnLog and debugElapsed >= DebugConfig.DebugLogInterval then
		debugElapsed = 0
		logEggDebug()
	end

	if zoneElapsed >= ZONE_POLL_INTERVAL then
		zoneElapsed = 0
		zones:Poll()
	end

	-- Target timeouts and exits are checked every frame so runs end on time; scheduling uses the shared tick
	local now = serverNow()
	targets:Sweep(now)

	if spawnElapsed >= SpawnerConfig.TickInterval then
		spawnElapsed = 0
		eggs:ExpireDue()
		spawner:Step(time())
		targetSpawner:Step(now)
	end
end)

--============================================================================
-- Shutdown
game:BindToClose(function()
	heartbeat:Disconnect()
	targetSpawner:Destroy()
	targets:Destroy()
	spawner:Destroy()
	eggs:Destroy()
	zones:Destroy()
end)
