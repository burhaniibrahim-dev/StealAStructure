-- Responsibility: Startup validation for the separated egg configs. Each file is checked on its own first, then
-- cross-file rules run (catalog ids, stack limits, fallback profile, templates). Types are checked before any
-- field is indexed, and every problem is returned at once as "<File>.<Field> ...". Pure: no Roblox services
--
-- inputs:
--   itemCatalog       Shared ItemDefintions
--   inventoryConfig   Shared InventoryConfig
--   pickupConfig      Configs/Eggs/PickupConfig
--   placementConfig   Configs/Eggs/PlacementConfig
--   spawnerConfig     Configs/Zones/SpawnerConfig
--   zoneIdConfig      Configs/Zones/IdConfig
--   tutorialConfig    Configs/TutorialConfig
--   debugConfig       Configs/DebugConfig
--   targetConfig      Configs/Targets/TargetConfig
--   hasTemplate       ((modelName: string) -> boolean)?   egg templates only; omitted in tests that don't cover them
-- Target models are not checked here: a missing one disables its type at runtime instead (Runner.Targets)

local ConfigValidator = {}

local MAX_ID_LENGTH = 32 -- matches string(1..32) in Remotes.blink
local NOTHING = "Nothing" -- reserved TargetTypeId for a public roll that spawns nothing
local MAX_U16 = 65535 -- Amount and Count are u16 in Remotes.blink
local MAX_PLACEMENT_ATTEMPTS = 50

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

local function isId(value)
	return type(value) == "string" and #value >= 1 and #value <= MAX_ID_LENGTH
end

local function newReport()
	local report = { errors = {} }
	function report.fail(message)
		table.insert(report.errors, message)
	end
	function report.check(condition, message)
		if not condition then
			report.fail(message)
		end
	end
	-- Returns true when `value` is a table; otherwise records `<path> must be a table`
	function report.isTable(value, path)
		if type(value) ~= "table" then
			report.fail(`{path} must be a table`)
			return false
		end
		return true
	end
	function report.range(range, path, whole)
		if not report.isTable(range, path) then
			return false
		end
		local valid = if whole
			then isWholeNumber(range.Min) and isWholeNumber(range.Max)
			else isFiniteNumber(range.Min) and isFiniteNumber(range.Max)
		report.check(valid and range.Min <= range.Max, `{path} must have {if whole then "whole" else "numeric"} Min <= Max`)
		return valid and range.Min <= range.Max
	end
	return report
end

-- File validators -------------------------------------------------------------------

local function validateInventory(report, config)
	if not report.isTable(config, "InventoryConfig") then
		return
	end
	report.check(
		isWholeNumber(config.MAX_STACK) and config.MAX_STACK >= 1 and config.MAX_STACK <= MAX_U16,
		`InventoryConfig.MAX_STACK must be a whole number 1..{MAX_U16}`
	)
end

local function validateCatalog(report, catalog)
	if not report.isTable(catalog, "ItemDefintions") then
		return
	end
	local fallbacks = 0
	for itemTypeId, definition in catalog do
		local path = `ItemDefintions.{itemTypeId}`
		report.check(isId(itemTypeId), `{path}: ItemTypeId must be a 1..{MAX_ID_LENGTH} character string`)
		if not report.isTable(definition, path) then
			continue
		end
		report.check(type(definition.DisplayName) == "string", `{path}.DisplayName must be a string`)
		report.check(
			type(definition.ModelName) == "string" and definition.ModelName ~= "",
			`{path}.ModelName must be a non-empty string`
		)
		report.check(isFiniteNumber(definition.Order), `{path}.Order must be a number`)
		report.check(
			definition.VisualFallback == nil or type(definition.VisualFallback) == "boolean",
			`{path}.VisualFallback must be a boolean`
		)
		if definition.VisualFallback == true then
			fallbacks += 1
		end
	end
	report.check(fallbacks == 1, `ItemDefintions must have exactly one entry with VisualFallback = true (found {fallbacks})`)
end

local function validatePickup(report, config)
	if not report.isTable(config, "PickupConfig") then
		return
	end
	report.check(isPositive(config.PickupLifetime), "PickupConfig.PickupLifetime must be > 0")
	report.check(isPositive(config.PickupRadius), "PickupConfig.PickupRadius must be > 0")
	report.check(isPositive(config.CollectRadius), "PickupConfig.CollectRadius must be > 0")
	report.check(
		not isFiniteNumber(config.PickupRadius)
			or not isFiniteNumber(config.CollectRadius)
			or config.CollectRadius >= config.PickupRadius,
		"PickupConfig.CollectRadius must be >= PickupRadius or client requests could never validate"
	)
	report.check(
		isWholeNumber(config.CollectRequestsPerTick) and config.CollectRequestsPerTick >= 1,
		"PickupConfig.CollectRequestsPerTick must be a whole number >= 1"
	)
	report.check(isNonNegative(config.InventoryFullCooldown), "PickupConfig.InventoryFullCooldown must be >= 0")
end

local function validatePlacement(report, config)
	if not report.isTable(config, "PlacementConfig") then
		return
	end
	for _, key in { "RaycastHeight", "RaycastDepth", "AnchorRaycastHeight" } do
		report.check(isPositive(config[key]), `PlacementConfig.{key} must be > 0`)
	end
	for _, key in { "SurfaceOffset", "PickupClearance", "CharacterClearance", "ObstructionRadius", "ExclusionPadding" } do
		report.check(isNonNegative(config[key]), `PlacementConfig.{key} must be >= 0`)
	end
	report.check(
		config.TrapPadding == nil or isNonNegative(config.TrapPadding),
		"PlacementConfig.TrapPadding must be >= 0 when set"
	)
	report.check(
		isFiniteNumber(config.MaxSlopeDegrees) and config.MaxSlopeDegrees >= 0 and config.MaxSlopeDegrees <= 90,
		"PlacementConfig.MaxSlopeDegrees must be 0..90"
	)
	if report.isTable(config.ForbiddenMaterials, "PlacementConfig.ForbiddenMaterials") then
		for index, name in config.ForbiddenMaterials do
			report.check(type(name) == "string", `PlacementConfig.ForbiddenMaterials[{index}] must be an Enum.Material name`)
		end
	end
end

local function validateSpawner(report, config)
	if not report.isTable(config, "SpawnerConfig") then
		return
	end
	report.check(isPositive(config.TickInterval), "SpawnerConfig.TickInterval must be > 0")
	if report.range(config.SpawnInterval, "SpawnerConfig.SpawnInterval", false) then
		report.check(isPositive(config.SpawnInterval.Min), "SpawnerConfig.SpawnInterval.Min must be > 0")
	end
	report.check(
		isFiniteNumber(config.SpawnIntervalCurve) and config.SpawnIntervalCurve > 0 and config.SpawnIntervalCurve <= 1,
		"SpawnerConfig.SpawnIntervalCurve must be > 0 and <= 1"
	)
	report.check(isNonNegative(config.FirstSpawnDelay), "SpawnerConfig.FirstSpawnDelay must be >= 0")
	report.check(isNonNegative(config.ReentryCreditMultiplier), "SpawnerConfig.ReentryCreditMultiplier must be >= 0")
	report.check(
		isWholeNumber(config.PlacementAttempts)
			and config.PlacementAttempts >= 1
			and config.PlacementAttempts <= MAX_PLACEMENT_ATTEMPTS,
		`SpawnerConfig.PlacementAttempts must be a whole number 1..{MAX_PLACEMENT_ATTEMPTS}`
	)

	local base, perZone, perPlayer = config.BasePickups, config.MaxPickups, config.MaxPickupsPerPlayer
	report.check(isWholeNumber(base) and base >= 0, "SpawnerConfig.BasePickups must be a whole number >= 0")
	report.check(isWholeNumber(perZone) and perZone >= 1, "SpawnerConfig.MaxPickups must be a whole number >= 1")
	-- The snapshot array length is a u16 in Blink
	report.check(
		isWholeNumber(perPlayer) and perPlayer >= 1 and perPlayer <= MAX_U16,
		`SpawnerConfig.MaxPickupsPerPlayer must be a whole number 1..{MAX_U16}`
	)
	if isWholeNumber(base) and isWholeNumber(perZone) and isWholeNumber(perPlayer) then
		report.check(base <= perZone, "SpawnerConfig.BasePickups must be <= MaxPickups (hard caps win over the target)")
		report.check(perZone <= perPlayer, "SpawnerConfig.MaxPickups must be <= MaxPickupsPerPlayer")
	end
end

-- Common to every weighted list: a non-empty array of tables with Weight > 0. Calls checkEntry(entry, entryPath)
local function validateWeightedList(report, list, path, checkEntry)
	if not report.isTable(list, path) then
		return
	end
	report.check(#list > 0, `{path} must be a non-empty list`)
	local totalWeight = 0
	for index, entry in list do
		local entryPath = `{path}[{index}]`
		if not report.isTable(entry, entryPath) then
			continue
		end
		report.check(isPositive(entry.Weight), `{entryPath}.Weight must be > 0`)
		if isPositive(entry.Weight) then
			totalWeight += entry.Weight
		end
		checkEntry(entry, entryPath)
	end
	report.check(#list == 0 or totalWeight > 0, `{path} total weight must be > 0`)
end

local PROFILE_KEYS = { Eggs = true, Targets = true }

-- Returns the zone profile table (or an empty one) so cross-file checks can still run
local function validateZoneIds(report, config)
	if not report.isTable(config, "IdConfig") then
		return {}
	end
	if not report.isTable(config.Zones, "IdConfig.Zones") then
		return {}
	end
	for zoneId, profile in config.Zones do
		local path = `IdConfig.Zones.{zoneId}`
		report.check(isId(zoneId), `{path}: ZoneId must be a 1..{MAX_ID_LENGTH} character string`)
		if not report.isTable(profile, path) then
			continue
		end
		for key in profile do
			report.check(PROFILE_KEYS[key] == true, `{path} has unknown key {key} (expected Eggs and/or Targets)`)
		end
		if profile.Eggs ~= nil then
			validateWeightedList(report, profile.Eggs, `{path}.Eggs`, function(entry, entryPath)
				report.check(isId(entry.ItemTypeId), `{entryPath}.ItemTypeId must be a 1..{MAX_ID_LENGTH} character string`)
				if report.range(entry.Amount, `{entryPath}.Amount`, true) then
					report.check(entry.Amount.Min >= 1, `{entryPath}.Amount.Min must be >= 1`)
				end
			end)
		end
		if profile.Targets ~= nil then
			validateWeightedList(report, profile.Targets, `{path}.Targets`, function(entry, entryPath)
				report.check(isId(entry.TargetTypeId), `{entryPath}.TargetTypeId must be a 1..{MAX_ID_LENGTH} character string`)
				if entry.TargetTypeId == NOTHING then
					return
				end
				if report.range(entry.Health, `{entryPath}.Health`, true) then
					report.check(entry.Health.Min >= 1, `{entryPath}.Health.Min must be >= 1`)
				end
				if report.range(entry.Scale, `{entryPath}.Scale`, true) then
					report.check(entry.Scale.Min >= 1, `{entryPath}.Scale.Min must be >= 1`)
				end
				if report.range(entry.RadiusGrowth, `{entryPath}.RadiusGrowth`, false) then
					report.check(entry.RadiusGrowth.Min > 0, `{entryPath}.RadiusGrowth.Min must be > 0`)
				end
			end)
		end
	end

	local fallback = config.FallbackZoneProfile
	report.check(
		fallback == false or (type(fallback) == "string" and config.Zones[fallback] ~= nil),
		"IdConfig.FallbackZoneProfile must be false or the name of an entry in IdConfig.Zones"
	)
	return config.Zones
end

local function validateTutorial(report, config)
	if not report.isTable(config, "TutorialConfig") then
		return
	end
	report.check(
		type(config.DefaultOrdinaryCollectionEnabled) == "boolean",
		"TutorialConfig.DefaultOrdinaryCollectionEnabled must be a boolean"
	)
end

local function validateTargetConfig(report, config)
	if not report.isTable(config, "TargetConfig") then
		return
	end
	for _, key in { "StarterLifetime", "TargetTime", "InitialRadius", "TestHitDamage", "HitRange" } do
		report.check(isPositive(config[key]), `TargetConfig.{key} must be > 0`)
	end
	for _, key in { "GraceTime", "AppearDuration", "DisappearDuration", "Clearance", "EggClearance", "RewardCooldown" } do
		report.check(isNonNegative(config[key]), `TargetConfig.{key} must be >= 0`)
	end
	report.check(isFiniteNumber(config.SurfaceOffset), "TargetConfig.SurfaceOffset must be a number")
	for _, key in { "StartersPerZone", "PlacementCandidates", "RunPlacementBatches", "RadiusGrowthSpawnLimit", "HitRequestsPerTick" } do
		report.check(isWholeNumber(config[key]) and config[key] >= 1, `TargetConfig.{key} must be a whole number >= 1`)
	end

	if report.isTable(config.Types, "TargetConfig.Types") then
		for typeId, definition in config.Types do
			local path = `TargetConfig.Types.{typeId}`
			report.check(isId(typeId), `{path}: TargetTypeId must be a 1..{MAX_ID_LENGTH} character string`)
			report.check(typeId ~= NOTHING, `{path}: "{NOTHING}" is reserved for the empty roll`)
			if report.isTable(definition, path) then
				report.check(
					type(definition.ModelName) == "string" and definition.ModelName ~= "",
					`{path}.ModelName must be a non-empty string`
				)
			end
		end
	end

	if report.isTable(config.RewardBrackets, "TargetConfig.RewardBrackets") then
		for index, bracket in config.RewardBrackets do
			local path = `TargetConfig.RewardBrackets[{index}]`
			if not report.isTable(bracket, path) then
				continue
			end
			report.check(isPositive(bracket.MinScore), `{path}.MinScore must be > 0`)
			validateWeightedList(report, bracket.Drops, `{path}.Drops`, function() end)
		end
	end
end

local function validateDebug(report, config)
	if not report.isTable(config, "DebugConfig") then
		return
	end
	report.check(type(config.DebugSpawnLog) == "boolean", "DebugConfig.DebugSpawnLog must be a boolean")
	report.check(not config.DebugSpawnLog or isPositive(config.DebugLogInterval), "DebugConfig.DebugLogInterval must be > 0")
end

-- Cross-file checks ----------------------------------------------------------------

local function validateDistributionItems(report, zones, catalog, maxStack)
	local catalogOk = type(catalog) == "table"
	local stackOk = isWholeNumber(maxStack)
	for zoneId, profile in zones do
		if type(profile) ~= "table" or type(profile.Eggs) ~= "table" then
			continue
		end
		for index, entry in profile.Eggs do
			if type(entry) ~= "table" then
				continue
			end
			local entryPath = `IdConfig.Zones.{zoneId}.Eggs[{index}]`
			if catalogOk and isId(entry.ItemTypeId) then
				report.check(
					catalog[entry.ItemTypeId] ~= nil,
					`{entryPath}.ItemTypeId "{entry.ItemTypeId}" is not in ItemDefintions`
				)
			end
			local amount = entry.Amount
			if stackOk and type(amount) == "table" and isWholeNumber(amount.Max) then
				report.check(amount.Max <= maxStack, `{entryPath}.Amount.Max must be <= InventoryConfig.MAX_STACK ({maxStack})`)
			end
		end
	end
end

-- Every zone Targets entry must name a configured type or Nothing
local function validateTargetTypes(report, zones, targetConfig)
	local types = type(targetConfig) == "table" and type(targetConfig.Types) == "table" and targetConfig.Types or nil
	if not types then
		return
	end
	for zoneId, profile in zones do
		if type(profile) ~= "table" or type(profile.Targets) ~= "table" then
			continue
		end
		for index, entry in profile.Targets do
			if type(entry) == "table" and isId(entry.TargetTypeId) and entry.TargetTypeId ~= NOTHING then
				report.check(
					types[entry.TargetTypeId] ~= nil,
					`IdConfig.Zones.{zoneId}.Targets[{index}].TargetTypeId "{entry.TargetTypeId}" is not in TargetConfig.Types`
				)
			end
		end
	end
end

-- Missing templates are critical: the server refuses to start rather than spawn eggs nobody can see
local function validateTemplates(report, catalog, hasTemplate)
	if hasTemplate == nil or type(catalog) ~= "table" then
		return
	end
	for _, definition in catalog do
		if type(definition) == "table" and type(definition.ModelName) == "string" and definition.ModelName ~= "" then
			report.check(hasTemplate(definition.ModelName), `MODEL OF {definition.ModelName} doesnt exist`)
		end
	end
end

function ConfigValidator.validate(inputs)
	local report = newReport()
	validateInventory(report, inputs.inventoryConfig)
	validateCatalog(report, inputs.itemCatalog)
	validatePickup(report, inputs.pickupConfig)
	validatePlacement(report, inputs.placementConfig)
	validateSpawner(report, inputs.spawnerConfig)

	local zones = validateZoneIds(report, inputs.zoneIdConfig)
	validateTutorial(report, inputs.tutorialConfig)
	validateDebug(report, inputs.debugConfig)
	validateTargetConfig(report, inputs.targetConfig)

	local maxStack = type(inputs.inventoryConfig) == "table" and inputs.inventoryConfig.MAX_STACK or nil
	validateDistributionItems(report, zones, inputs.itemCatalog, maxStack)
	validateTargetTypes(report, zones, inputs.targetConfig)
	validateTemplates(report, inputs.itemCatalog, inputs.hasTemplate)

	return #report.errors == 0, report.errors
end

-- Raises one error listing every problem. Runner calls this before building any gameplay service
function ConfigValidator.assert(inputs)
	local ok, errors = ConfigValidator.validate(inputs)
	if not ok then
		error("[Config] Invalid configuration:\n  - " .. table.concat(errors, "\n  - "), 2)
	end
end

-- The catalog entry flagged VisualFallback, or nil. Validation guarantees exactly one
function ConfigValidator.findVisualFallback(catalog)
	for itemTypeId, definition in catalog do		
		if definition.VisualFallback == true then
			return itemTypeId
		end
	end
	return nil
end

return ConfigValidator
