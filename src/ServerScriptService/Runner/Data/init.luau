-- Responsibility: Runner setup for data-related startup work. Each child module builds one data service.

local _Players = require(script._Players)

local Data = {}

-- deps: defaultOrdinaryCollectionEnabled (TutorialConfig.DefaultOrdinaryCollectionEnabled)
-- Returns the PlayerDataService
function Data.Init(deps)
	return _Players.Init({ defaultOrdinaryCollectionEnabled = deps.defaultOrdinaryCollectionEnabled })
end

return Data
