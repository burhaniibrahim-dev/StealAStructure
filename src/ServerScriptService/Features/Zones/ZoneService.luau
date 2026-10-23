local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local ZoneDetection = require(ServerScriptService.Features.Zones.ZoneDetection)
local SpawnTrackRegistry = require(ServerScriptService.Features.Zones.SpawnTrackRegistry)
local ZoneSpawner = require(ServerScriptService.Features.Zones.ZoneSpawner)

local ZoneService = {}
local ZONES = {}

local function TagAdded(basepart)
    local Id = string.gsub(HttpService:GenerateGUID(false), "-", ""):sub(1, 5)
    basepart:SetAttribute("Id", Id)
    table.insert(ZONES, basepart)
end

local function CheckPlayers()
    if #Players:GetPlayers() == 0 then return end
    for i, player in Players:GetPlayers() do
        local ZoneId = ZoneDetection(player, ZONES)
        local TrackData = SpawnTrackRegistry:GetPlayer(player)

        if ZoneId then
            if TrackData then
                if ZoneId ~= TrackData.Id or ZoneId == nil then
                    SpawnTrackRegistry:Close(player)
                elseif SpawnTrackRegistry:IsDead(player) then
                    SpawnTrackRegistry:Restart(player)
                end
            else
                SpawnTrackRegistry:Create(player, ZoneId, ZoneSpawner)
            end
        end

    end
end

local function WatchZones()
    return task.spawn(function()
        while true do

            task.wait(0.3)
            CheckPlayers()

        end
    end)
end

function ZoneService.init()
    ZONES = CollectionService:GetTagged("SpawnZone")
    CollectionService:GetInstanceAddedSignal("SpawnZone"):Connect(TagAdded)

    for _, zone in ZONES do
        local Id = string.gsub(HttpService:GenerateGUID(false), "-", ""):sub(1, 5)
        zone:SetAttribute("Id", Id)
    end

    WatchZones()
end


return ZoneService