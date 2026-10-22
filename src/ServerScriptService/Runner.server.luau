-- Responsibility: The only server Script. Starts every server feature in a fixed order

local ServerScriptService = game:GetService("ServerScriptService")

-- Networker first so its remotes exist before clients wait on them
local _Networker = require(ServerScriptService.Networker.Server)
local _Features = ServerScriptService.Features

--============================================================================

local ItemService = require(_Features.Items.ItemService)
local ZoneService = require(_Features.Zones.ZoneService)

ItemService.init()
ZoneService.init()