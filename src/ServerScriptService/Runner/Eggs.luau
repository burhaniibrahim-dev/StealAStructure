-- Responsibility: Runner setup for the floor egg system. Builds the Workspace pickup folder, placement and its
-- exclusions, the Roblox world/model adapters, personal scripted-session tracks, and the EggService itself.
-- The shared EggRegistry is created by Runner and passed in, so the ZoneSpawner can be given the same one.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local _Features = ServerScriptService.Features

local RobloxPlayers = require(ServerScriptService.Util.RobloxPlayers)
local Signal = require(ServerScriptService.Util.Signal)
local EggService = require(_Features.Items.Eggs.EggService)
local ExclusionProviders = require(_Features.Items.Eggs.ExclusionProviders)
local PickupPlacement = require(_Features.Items.Eggs.PickupPlacement)
local RobloxPickupWorld = require(_Features.Items.Eggs.RobloxPickupWorld)
local SpawnTrackRegistry = require(_Features.Zones.SpawnTrackRegistry)
local ZoneDetection = require(_Features.Zones.ZoneDetection)
local ZoneService = require(_Features.Zones.ZoneService)

local EXCLUSION_TAG = "PickupExclusion"

local Eggs = {}

-- deps:
--   config            PickupConfig
--   itemDefinitions   shared ItemDefinitions
--   playerData        PlayerDataService
--   inventory         InventoryService
--   zones             ZoneService
--   eggRegistry       EggRegistry (shared with the ZoneSpawner)
--   rng               Random (shared with the ZoneSpawner)
--   getActivePlayers  () -> {Player}
-- Returns the EggService

function Eggs.Init(deps)
	local config = deps.config
	local zones = deps.zones

	local pickupFolder = Instance.new("Folder")
	pickupFolder.Name = "Pickups"
	pickupFolder.Parent = workspace

	local traps = ExclusionProviders.NoTrapsProvider()
	if traps.IsPlaceholder then
		warn("[Pickups] Trap exclusion uses NoTrapsProvider: no trap system exists yet, so trap avoidance is inactive.")
	end

	local placement = PickupPlacement.new({
		config = config.Placement,
		detection = ZoneDetection,
		registry = deps.eggRegistry,
		world = RobloxPickupWorld.newWorld({
			workspace = workspace,
			pickupFolder = pickupFolder,
			zoneTag = ZoneService.ZONE_TAG,
		}),
		getAnchors = function(zoneId)
			return zones:GetAnchors(zoneId)
		end,
		exclusions = {
			ExclusionProviders.TaggedProvider(
				"Structures and interaction points",
				CollectionService,
				EXCLUSION_TAG,
				workspace
			),
		},
		traps = traps,
	})

	local eggs -- assigned below; the model factory's touch handler needs it
	local assets = ReplicatedStorage:FindFirstChild("Assets")

	eggs = EggService.new({
		config = config,
		itemDefinitions = deps.itemDefinitions,
		registry = deps.eggRegistry,
		placement = placement,
		detection = ZoneDetection,
		zones = zones,
		inventory = deps.inventory,
		data = deps.playerData,
		tracks = SpawnTrackRegistry.new({ spawn = task.spawn, cancel = task.cancel }),
		models = RobloxPickupWorld.newModelFactory({
			folder = pickupFolder,
			itemDefinitions = deps.itemDefinitions,
			templates = assets and assets:FindFirstChild("Pickups"),
			pickupRadius = config.PickupRadius,
			onTouched = function(pickupId, player)
				eggs:HandleTouch(pickupId, player)
			end,
		}),
		scheduler = { Delay = task.delay, Cancel = task.cancel },
		now = time, -- elapsed game time; matches task.delay
		rng = deps.rng,
		getPlayers = deps.getActivePlayers,
		isPlayerPresent = RobloxPlayers.isPlayerPresent,
		getRootPosition = RobloxPlayers.getRootPosition,
		Signal = Signal,
	})

	return eggs
end

return Eggs
