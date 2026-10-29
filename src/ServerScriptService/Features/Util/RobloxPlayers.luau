-- Responsibility: Non-yielding Roblox player lookups shared by data, zones, and eggs.

local Players = game:GetService("Players")

local RobloxPlayers = {}

-- Non-yielding. nil unless the player has a living character with a HumanoidRootPart
function RobloxPlayers.getRootPosition(player)
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	return root.Position
end

function RobloxPlayers.isPlayerPresent(player)
	return player.Parent == Players
end

return RobloxPlayers
