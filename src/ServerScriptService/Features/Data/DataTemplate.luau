-- Responsibility: The saved profile shape. ProfileStore reconciles missing keys into existing saves.
-- Only server code reads this; nothing here is sent to other players.

return function(pickupConfig)
	return {
		Inventory = {}, -- [ItemTypeId] = count, 0..MAX_STACK

		Tutorial = {
			-- Ordinary floor pickups are refused while false. The tutorial flips this via
			-- EggService:SetCollectionEnabled when its collection stage starts
			OrdinaryCollectionEnabled = pickupConfig.Tutorial.DefaultOrdinaryCollectionEnabled,
		},

		-- Written only by the deferred PickupAnalytics (inactive for MVP). Kept so existing saves stay unchanged
		Milestones = {
			FirstScriptedCollection = false,
			FirstOrdinaryCollection = false,
		},
	}
end
