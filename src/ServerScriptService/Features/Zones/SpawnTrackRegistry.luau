local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Janitor = require(ReplicatedStorage.Packages.Janitor)

local SpawnTrackRegistry  = {}

local Registered = {} --Table of Players and their zones
local TASK_KEY = "SpawnTask"

function SpawnTrackRegistry:Create(player, zoneID, _task)
    local janitor = Janitor.new()
    janitor:Add(task.spawn(_task), true, TASK_KEY)

    Registered[player.UserId] = {
        Id = zoneID,
        TaskFn = _task,
        Janitor = janitor
    }
    print("CREATED!")
end

function SpawnTrackRegistry:GetPlayers()
    return Registered
end

function SpawnTrackRegistry:GetPlayer(player)
    return Registered[player.UserId] or nil
end

function SpawnTrackRegistry:GetStatus(player)
    local data = Registered[player.UserId]
    if not data then return nil end

    local thread = data.Janitor:Get(TASK_KEY)
    if not thread then return nil end
    return coroutine.status(thread)
end

function SpawnTrackRegistry:IsDead(player)
    return self:GetStatus(player) == "dead"
end

function SpawnTrackRegistry:Restart(player)
    local data = Registered[player.UserId]
    if not data then return end

    -- Adding under the same key cleans up the old thread first
    data.Janitor:Add(task.spawn(data.TaskFn), true, TASK_KEY)
    print("RESTARTED SPAWN TRACK")
end

function SpawnTrackRegistry:Close(player)
    print("CLOSING SPAWN TRACK")
    local data = Registered[player.UserId]
    if data then
        data.Janitor:Destroy()
    end

    Registered[player.UserId] = nil
end

return SpawnTrackRegistry
