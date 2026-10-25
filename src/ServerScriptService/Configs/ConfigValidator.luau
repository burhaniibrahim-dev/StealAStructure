-- Responsibility: Startup validation for PickupConfig against the shared ItemDefinitions.
-- Returns every problem at once so a broken config is fixed in one pass. Pure: no Roblox services

local ConfigValidator = {}

local MAX_ID_LENGTH = 32 -- matches string(1..32) in Remotes.blink

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isPositive(value)
	return isFiniteNumber(value) and value > 0
end

local function isNonNegative(value)
	return isFiniteNumber(value) and value >= 0
end

local function isWholeNumber(value)
	return isFiniteNumber(value) and math.floor(value) == value
end

function ConfigValidator.validate(config, itemDefinitions)
	local errors = {}
	local function check(condition, message)
		if not condition then
			table.insert(errors, message)
		end
	end
	local function checkRange(range, path, whole)
		if type(range) ~= "table" then
			table.insert(errors, `{path} must be a table with Min and Max`)
			return
		end
		local valid = if whole
			then isWholeNumber(range.Min) and isWholeNumber(range.Max)
			else isFiniteNumber(range.Min) and isFiniteNumber(range.Max)
		check(valid and range.Min <= range.Max, `{path} must have numeric Min <= Max`)
	end

	local maxStack = itemDefinitions.MAX_STACK
	check(isWholeNumber(maxStack) and maxStack >= 1 and maxStack <= 65535, "ItemDefinitions.MAX_STACK must be 1..65535")
	check(type(itemDefinitions.Items) == "table", "ItemDefinitions.Items must be a table")
	for itemTypeId in itemDefinitions.Items or {} do
		check(
			type(itemTypeId) == "string" and #itemTypeId >= 1 and #itemTypeId <= MAX_ID_LENGTH,
			`ItemTypeId "{itemTypeId}" must be 1..{MAX_ID_LENGTH} characters`
		)
	end

	check(config.DebugSpawnLog == nil or type(config.DebugSpawnLog) == "boolean", "DebugSpawnLog must be a boolean")
	check(not config.DebugSpawnLog or isPositive(config.DebugLogInterval), "DebugLogInterval must be > 0")
	check(isPositive(config.PickupLifetime), "PickupLifetime must be > 0")
	check(isWholeNumber(config.ServerMaxPickups) and config.ServerMaxPickups >= 0, "ServerMaxPickups must be a whole number >= 0")
	check(isPositive(config.PickupRadius), "PickupRadius must be > 0")
	check(isPositive(config.SweepRadius), "SweepRadius must be > 0")
	check(isPositive(config.CollectRadius), "CollectRadius must be > 0")
	check(
		isFiniteNumber(config.CollectRadius) and isFiniteNumber(config.SweepRadius) and config.CollectRadius >= config.SweepRadius,
		"CollectRadius must be >= SweepRadius or swept pickups could never validate"
	)
	check(isPositive(config.ProximitySweepInterval), "ProximitySweepInterval must be > 0")
	check(isNonNegative(config.InventoryFullCooldown), "InventoryFullCooldown must be >= 0")

	local schedule = config.Schedule
	if type(schedule) ~= "table" then
		table.insert(errors, "Schedule must be a table")
	else
		check(isPositive(schedule.TickInterval), "Schedule.TickInterval must be > 0")
		checkRange(schedule.SpawnInterval, "Schedule.SpawnInterval", false)
		check(
			type(schedule.SpawnInterval) == "table" and isPositive(schedule.SpawnInterval.Min),
			"Schedule.SpawnInterval.Min must be > 0"
		)
		check(isNonNegative(schedule.RatePerExtraPlayer), "Schedule.RatePerExtraPlayer must be >= 0")
		check(isFiniteNumber(schedule.MaxRateMultiplier) and schedule.MaxRateMultiplier >= 1, "Schedule.MaxRateMultiplier must be >= 1")
		check(isWholeNumber(schedule.PopulationCap) and schedule.PopulationCap >= 1, "Schedule.PopulationCap must be a whole number >= 1")
	end

	local placement = config.Placement
	if type(placement) ~= "table" then
		table.insert(errors, "Placement must be a table")
	else
		check(
			isWholeNumber(placement.MaxAttempts) and placement.MaxAttempts >= 1 and placement.MaxAttempts <= 50,
			"Placement.MaxAttempts must be a whole number 1..50"
		)
		for _, key in { "RaycastHeight", "RaycastDepth", "AnchorRaycastHeight" } do
			check(isPositive(placement[key]), `Placement.{key} must be > 0`)
		end
		for _, key in
			{ "SurfaceOffset", "PickupClearance", "CharacterClearance", "ObstructionRadius", "ExclusionPadding", "TrapPadding" }
		do
			check(isNonNegative(placement[key]), `Placement.{key} must be >= 0`)
		end
		check(
			isFiniteNumber(placement.MaxSlopeDegrees) and placement.MaxSlopeDegrees >= 0 and placement.MaxSlopeDegrees <= 90,
			"Placement.MaxSlopeDegrees must be 0..90"
		)
		check(type(placement.ForbiddenMaterials) == "table", "Placement.ForbiddenMaterials must be a list of Enum.Material names")
		for _, name in placement.ForbiddenMaterials or {} do
			check(type(name) == "string", "Placement.ForbiddenMaterials entries must be strings")
		end
	end

	local zones = config.Zones
	if type(zones) ~= "table" then
		table.insert(errors, "Zones must be a table")
		zones = {}
	end
	for zoneId, profile in zones do
		local path = `Zones.{zoneId}`
		if type(profile) ~= "table" then
			table.insert(errors, `{path} must be a table`)
			continue
		end
		check(isWholeNumber(profile.BasePickups) and profile.BasePickups >= 0, `{path}.BasePickups must be a whole number >= 0`)
		check(isNonNegative(profile.PickupsPerExtraPlayer), `{path}.PickupsPerExtraPlayer must be >= 0`)
		check(isWholeNumber(profile.MaxPickups) and profile.MaxPickups >= 0, `{path}.MaxPickups must be a whole number >= 0`)
		check(
			not isFiniteNumber(profile.MaxPickups) or not isFiniteNumber(config.ServerMaxPickups) or profile.MaxPickups <= config.ServerMaxPickups,
			`{path}.MaxPickups must not exceed ServerMaxPickups`
		)

		local distribution = profile.Distribution
		if type(distribution) ~= "table" or #distribution == 0 then
			table.insert(errors, `{path}.Distribution must be a non-empty list`)
			continue
		end
		local totalWeight = 0
		for index, entry in distribution do
			local entryPath = `{path}.Distribution[{index}]`
			local known = type(entry.ItemTypeId) == "string" and (itemDefinitions.Items or {})[entry.ItemTypeId] ~= nil
			check(known, `{entryPath}.ItemTypeId "{entry.ItemTypeId}" is not in ItemDefinitions.Items`)
			check(isPositive(entry.Weight), `{entryPath}.Weight must be > 0`)
			if isPositive(entry.Weight) then
				totalWeight += entry.Weight
			end
			checkRange(entry.Amount, `{entryPath}.Amount`, true)
			if type(entry.Amount) == "table" and isWholeNumber(entry.Amount.Min) and isWholeNumber(entry.Amount.Max) then
				check(
					entry.Amount.Min >= 1 and isWholeNumber(maxStack) and entry.Amount.Max <= maxStack,
					`{entryPath}.Amount must be within 1..MAX_STACK`
				)
			end
		end
		check(totalWeight > 0, `{path}.Distribution total weight must be > 0`)
	end

	local fallback = config.FallbackZoneProfile
	check(
		fallback == false or (type(fallback) == "string" and zones[fallback] ~= nil),
		"FallbackZoneProfile must be false or the name of an entry in Zones"
	)

	local tutorial = config.Tutorial
	if type(tutorial) ~= "table" then
		table.insert(errors, "Tutorial must be a table")
	else
		check(type(tutorial.DefaultOrdinaryCollectionEnabled) == "boolean", "Tutorial.DefaultOrdinaryCollectionEnabled must be a boolean")
		check(isPositive(tutorial.ReservedLifetime), "Tutorial.ReservedLifetime must be > 0")
		check(isWholeNumber(tutorial.MaxReservedPerPlayer) and tutorial.MaxReservedPerPlayer >= 1, "Tutorial.MaxReservedPerPlayer must be >= 1")
		check(
			isWholeNumber(tutorial.MaxReservedAmount) and tutorial.MaxReservedAmount >= 1 and isWholeNumber(maxStack) and tutorial.MaxReservedAmount <= maxStack,
			"Tutorial.MaxReservedAmount must be within 1..MAX_STACK"
		)
	end

	return #errors == 0, errors
end

-- Raises one error listing every problem. Runner calls this before starting the pickup system
function ConfigValidator.assert(config, itemDefinitions)
	local ok, errors = ConfigValidator.validate(config, itemDefinitions)
	if not ok then
		error("[PickupConfig] Invalid configuration:\n  - " .. table.concat(errors, "\n  - "), 2)
	end
end

return ConfigValidator
