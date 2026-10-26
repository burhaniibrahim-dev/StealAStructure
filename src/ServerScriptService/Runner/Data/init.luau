-- Responsibility: Runner setup for data-related startup work. Each child module builds one data service.

local _Players = require(script._Players)

local Data = {}

-- deps: config (PickupConfig)
-- Returns the PlayerDataService
function Data.Init(deps)
	return _Players.Init({ config = deps.config })
end

return Data
