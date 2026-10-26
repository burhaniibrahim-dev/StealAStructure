-- Responsibility: Runner setup for persistent player data. Builds the ProfileStore session adapter and the
-- PlayerDataService around it. Named _Players so it never reads as Roblox's Players service.
-- PlayerDataService itself lives in Features/Data; join/leave connections stay in Runner.

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileStore = require(ServerScriptService.ServerPackages.ProfileStore)
local DataTemplate = require(ServerScriptService.Features.Data.DataTemplate)
local PlayerDataService = require(ServerScriptService.Features.Data.PlayerDataService)
local RobloxPlayers = require(ServerScriptService.Util.RobloxPlayers)
local Signal = require(ServerScriptService.Util.Signal)

local PROFILE_STORE_NAME = "PlayerData_v1"

local _Players = {}

-- deps: config (PickupConfig; seeds the data template)
-- Returns the PlayerDataService
function _Players.Init(deps)
	local profileStore = ProfileStore.New(PROFILE_STORE_NAME, DataTemplate(deps.config))

	return PlayerDataService.new({
		Signal = Signal,
		isPresent = RobloxPlayers.isPlayerPresent,
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
end

return _Players
