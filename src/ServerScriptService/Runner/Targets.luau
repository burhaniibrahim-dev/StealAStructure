-- Responsibility: Runner setup for the target minigame. Builds the Workspace.Targets world adapter, the ground
-- probe and placement, the registry, rewards, TargetService, and the public TargetSpawner.
-- Schedules nothing: Runner drives Sweep / Step from Heartbeat and wires networking and cleanup.
-- Target models are not required at startup: a missing one disables its type with a warning.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local _Features = ServerScriptService.Features

local RobloxPlayers = require(_Features.Util.RobloxPlayers)
local Signal = require(_Features.Util.Signal)
local ExclusionProviders = require(_Features.Items.ExclusionProviders)
local GroundProbe = require(_Features.Items.GroundProbe)
local RobloxPickupWorld = require(_Features.Items.Eggs.RobloxPickupWorld)
local ZoneDetection = require(_Features.Zones.ZoneDetection)
local ZoneService = require(_Features.Zones.ZoneService)
local RobloxTargetWorld = require(_Features.Targets.RobloxTargetWorld)
local TargetPlacement = require(_Features.Targets.TargetPlacement)
local TargetRegistry = require(_Features.Targets.TargetRegistry)
local TargetRewards = require(_Features.Targets.TargetRewards)
local TargetService = require(_Features.Targets.TargetService)
local TargetSpawner = require(_Features.Targets.TargetSpawner)

local EXCLUSION_TAG = "PickupExclusion"

local Targets = {}

-- deps:
--   targetConfig      TargetConfig
--   placementConfig   PlacementConfig (shared ground rules, obstruction, exclusion padding)
--   spawnerConfig     SpawnerConfig (TickInterval, FirstSpawnDelay)
--   zoneConfig        IdConfig
--   zones             ZoneService
--   eggRegistry       EggRegistry
--   playerData        PlayerDataService
--   rng               Random
--   now               () -> number   server time (workspace:GetServerTimeNow)
-- Returns TargetService, TargetSpawner, TargetRegistry, and the Workspace.Targets folder (eggs need the last two
-- to keep clear of targets, so Runner builds targets before eggs)
function Targets.Init(deps)
	local config = deps.targetConfig
	local placementConfig = deps.placementConfig
	local zones = deps.zones

	local world, folder = RobloxTargetWorld.new({
		replicatedStorage = ReplicatedStorage,
		workspace = workspace,
		config = config,
	})
	RobloxTargetWorld.checkTypes(world, config.Types, warn)

	-- Same ground rules as eggs; rays also skip existing target models
	local pickupWorld = RobloxPickupWorld.newWorld({
		workspace = workspace,
		zoneTag = ZoneService.ZONE_TAG,
		ignore = { folder },
	})
	local registry = TargetRegistry.new()
	local placement = TargetPlacement.new({
		config = config,
		placementConfig = placementConfig,
		ground = GroundProbe.new({
			world = pickupWorld,
			maxSlopeDegrees = placementConfig.MaxSlopeDegrees,
			forbiddenMaterials = placementConfig.ForbiddenMaterials,
		}),
		detection = ZoneDetection,
		getZones = function()
			return zones:GetZones()
		end,
		world = pickupWorld,
		eggRegistry = deps.eggRegistry,
		targetRegistry = registry,
		exclusions = {
			ExclusionProviders.TaggedProvider("Structures and interaction points", CollectionService, EXCLUSION_TAG, workspace),
		},
	})

	local targets = TargetService.new({
		config = config,
		batchInterval = deps.spawnerConfig.TickInterval,
		registry = registry,
		placement = placement,
		world = world,
		-- No payout yet: reward items are not designed, so runs settle with no reward and no cooldown
		rewards = TargetRewards.new({ brackets = config.RewardBrackets, rng = deps.rng }),
		zones = zones,
		data = deps.playerData,
		isPlayerPresent = RobloxPlayers.isPlayerPresent,
		getRootPosition = RobloxPlayers.getRootPosition,
		now = deps.now,
		rng = deps.rng,
		Signal = Signal,
	})

	local spawner = TargetSpawner.new({
		config = config,
		spawnerConfig = deps.spawnerConfig,
		zoneConfig = deps.zoneConfig,
		zones = zones,
		targets = targets,
		registry = registry,
		rng = deps.rng,
	})

	return targets, spawner, registry, folder
end

return Targets
