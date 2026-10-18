--Responsibility: Receive the client's click event on the server
local ServerScriptService = game:GetService("ServerScriptService")

local Networker = require(ServerScriptService.Networker.Server)

local ClientClickHandler = {}

local initialized = false

local function onClientEvent(player: Player, data: { Position: Vector3, Tag: string })
	print("Clicked A Hitbox: " .. player.Name)
end

function ClientClickHandler.Init()
	if initialized then
		return
	end
	initialized = true

	Networker.ClickEvent.On(onClientEvent)
end

return ClientClickHandler
