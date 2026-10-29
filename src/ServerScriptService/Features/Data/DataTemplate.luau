-- Responsibility: The saved profile shape. ProfileStore reconciles missing keys into existing saves.
-- Only server code reads this; nothing here is sent to other players.

-- defaultOrdinaryCollectionEnabled: TutorialConfig.DefaultOrdinaryCollectionEnabled
return function(defaultOrdinaryCollectionEnabled)
	return {
		Inventory = {}, -- [ItemTypeId] = count, 0..InventoryConfig.MAX_STACK

		Tutorial = {
			-- Ordinary floor pickups are refused while false. The tutorial flips this when its collection stage starts
			OrdinaryCollectionEnabled = defaultOrdinaryCollectionEnabled,
		},

		-- Written only by the deferred PickupAnalytics (inactive for MVP). Kept so existing saves stay unchanged
		Milestones = {
			FirstScriptedCollection = false,
			FirstOrdinaryCollection = false,
		},
	}
end
