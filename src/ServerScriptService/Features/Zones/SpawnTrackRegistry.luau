local SpawnTrackRegistry  = {}

local Registered = {} --Table of Players and their zones

function SpawnTrackRegistry:Create(player, zoneID)
end

function SpawnTrackRegistry:GetPlayers()
    return Registered
end

function SpawnTrackRegistry:GetPlayer(player)
    return Registered[player.UserId] or {}
end

function SpawnTrackRegistry:Close(player)
end

return SpawnTrackRegistry