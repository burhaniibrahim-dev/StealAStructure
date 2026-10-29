-- Responsibility: Runner setup for zones, in two stages because the spawner needs the egg service:
--   Zones.Init          builds the ZoneService (before eggs)
--   Zones.StartSpawner  builds the ZoneSpawner (after eggs)
-- Neither stage schedules work or binds tags. Runner drives Poll/Step from Heartbeat and binds zone tags
-- once its wiring is connected.

local ServerScriptService = game:GetService("ServerScriptService")

local _Features = ServerScriptService.Features

local RobloxPlayers = require(_Features.Util.RobloxPlayers)
local Signal = require(_Features.Util.Signal)
local ZoneDetection = require(_Features.Zones.ZoneDetection)
local ZoneService = require(_Features.Zones.ZoneService)
local ZoneSpawner = require(_Features.Zones.ZoneSpawner)

local Zones = {}

-- deps: getActivePlayers () -> {Player}   only these count toward zone population
-- Returns the ZoneService
function Zones.Init(deps)
	return ZoneService.new({
		Signal = Signal,
		Detection = ZoneDetection,
		getPlayers = deps.getActivePlayers,
		getRootPosition = RobloxPlayers.getRootPosition,
	})
end

-- deps: spawnConfig (SpawnerConfig), zoneConfig (IdConfig), itemCatalog, fallbackItemTypeId,
--       templates ({ Has }), zones (ZoneService), eggs (EggService), eggRegistry (EggRegistry),
--       getActivePlayers () -> {Player}, rng (Random)
-- Returns the ZoneSpawner
function Zones.StartSpawner(deps)
	return ZoneSpawner.new({
		spawnerConfig = deps.spawnConfig,
		zoneConfig = deps.zoneConfig,
		itemCatalog = deps.itemCatalog,
		fallbackItemTypeId = deps.fallbackItemTypeId,
		templates = deps.templates,
		zones = deps.zones,
		eggs = deps.eggs,
		eggRegistry = deps.eggRegistry,
		getPlayers = deps.getActivePlayers,
		getRootPosition = RobloxPlayers.getRootPosition,
		rng = deps.rng,
	})
end

return Zones
