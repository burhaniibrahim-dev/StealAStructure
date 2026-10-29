-- Responsibility: Tutorial defaults. Saved-data field names live in Features/Data/DataTemplate.
return {
	-- Saved default for new profiles. Set false when the tutorial ships so new players
	-- can't take ordinary pickups until their collection stage enables it
	DefaultOrdinaryCollectionEnabled = true,

	-- Scripted tutorial eggs. No consumer until the tutorial module boundary is decided
	ReservedLifetime = 300,
	MaxReservedPerPlayer = 10,
	MaxReservedAmount = 25, -- tutorial pickups may be larger than ordinary ones
}
