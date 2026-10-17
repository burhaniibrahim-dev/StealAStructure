-- Responsibility: The only server Script. Starts every server feature in a fixed order

local ServerScriptService = game:GetService("ServerScriptService")

-- Networker first so its remotes exist before clients wait on them
local _Networker = require(ServerScriptService.Networker.Server)

--============================================================================
