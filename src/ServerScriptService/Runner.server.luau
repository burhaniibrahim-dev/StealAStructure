-- Responsibility: The only server Script. Starts every server feature in a fixed order

local ServerScriptService = game:GetService("ServerScriptService")

local ClientClickHandler = require(ServerScriptService.Features.ClientClickHandler)

ClientClickHandler.Init()

--============================================================================
