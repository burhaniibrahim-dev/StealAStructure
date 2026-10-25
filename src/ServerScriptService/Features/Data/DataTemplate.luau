-- Responsibility: The saved profile shape. ProfileStore reconciles missing keys into existing saves.
-- Only server code reads this; nothing here is sent to other players.

return function(pickupConfig)
	return {
		Inventory = {}, -- [ItemTypeId] = count, 0..MAX_STACK

		Tutorial = {
			-- Ordinary floor pickups are refused while false. The tutorial flips this via
			-- ItemService:SetCollectionEnabled when its collection stage starts
			OrdinaryCollectionEnabled = pickupConfig.Tutorial.DefaultOrdinaryCollectionEnabled,
		},

		Milestones = {
			FirstScriptedCollection = false,
			FirstOrdinaryCollection = false,
		},
	}
end
