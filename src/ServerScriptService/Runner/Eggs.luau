-- Responsibility: Runner setup for the floor egg system. Builds placement and its exclusions, the Roblox world
-- adapter, personal scripted-session tracks, and the EggService itself. No Workspace folder and no models:
-- egg records are data, and each owner's client renders its own.
-- The shared EggRegistry is created by Runner and passed in, so the ZoneSpawner works on the same records.

local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")

local _Features = ServerScriptService.Features

local RobloxPlayers = require(_Features.Util.RobloxPlayers)
local Signal = require(_Features.Util.Signal)
local EggService = require(_Features.Items.Eggs.EggService)
local ExclusionProviders = require(_Features.Items.ExclusionProviders)
local PickupPlacement = require(_Features.Items.PickupPlacement)
local RobloxPickupWorld = require(_Features.Items.Eggs.RobloxPickupWorld)
local SpawnTrackRegistry = require(_Features.Zones.SpawnTrackRegistry)
local ZoneDetection = require(_Features.Zones.ZoneDetection)
local ZoneService = require(_Features.Zones.ZoneService)

local EXCLUSION_TAG = "PickupExclusion"

local Eggs = {}

-- deps:
--   pickupConfig      PickupConfig
--   placementConfig   PlacementConfig
--   spawnerConfig     SpawnerConfig (caps and the collection rate-limit window)
--   itemCatalog       Shared ItemDefintions
--   maxStack          InventoryConfig.MAX_STACK
--   playerData        PlayerDataService
--   inventory         InventoryService
--   zones             ZoneService
--   eggRegistry       EggRegistry (shared with the ZoneSpawner)
--   rng               Random (shared with the ZoneSpawner)
-- Returns the EggService

function Eggs.Init(deps)
	local zones = deps.zones

	-- No trap system exists yet and PlacementConfig.TrapPadding is commented out, so no trap provider is passed
	local placement = PickupPlacement.new({
		config = deps.placementConfig,
		detection = ZoneDetection,
		registry = deps.eggRegistry,
		world = RobloxPickupWorld.newWorld({
			workspace = workspace,
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
	})

	return EggService.new({
		pickupConfig = deps.pickupConfig,
		spawnerConfig = deps.spawnerConfig,
		itemCatalog = deps.itemCatalog,
		maxStack = deps.maxStack,
		registry = deps.eggRegistry,
		placement = placement,
		zones = zones,
		inventory = deps.inventory,
		data = deps.playerData,
		tracks = SpawnTrackRegistry.new({ spawn = task.spawn, cancel = task.cancel }),
		scheduler = { Delay = task.delay, Cancel = task.cancel },
		now = time, -- elapsed game time; matches task.delay
		rng = deps.rng,
		isPlayerPresent = RobloxPlayers.isPlayerPresent,
		getRootPosition = RobloxPlayers.getRootPosition,
		Signal = Signal,
	})
end

return Eggs
