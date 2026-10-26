-- Responsibility: Owns registered spawn zones, authored spawn anchors, and which zone each player is in.
-- Zones are BaseParts tagged "SpawnZone" with an authored, stable "ZoneId" string attribute.
-- Polling reads positions without yielding. Spawn timing lives in ZoneSpawner; egg pickups live in EggService.
--
-- Zone part attributes:
--   ZoneId       (string, required, 1..32 chars, unique) - stable key into PickupConfig.Zones
--   Priority     (number, default 0) - highest wins where zones overlap; equal overlapping priorities are an error
--   VerticalMode ("Column" | "Volume", default "Column") - see ZoneDetection

local ZoneService = {}
ZoneService.__index = ZoneService

ZoneService.ZONE_TAG = "SpawnZone"
ZoneService.ANCHOR_TAG = "PickupAnchor"

local MAX_ZONE_ID_LENGTH = 32
local WATCHED_ATTRIBUTES = { "ZoneId", "Priority", "VerticalMode" }

local function describe(instance)
	local ok, name = pcall(function()
		return instance:GetFullName()
	end)
	return if ok then name else tostring(instance)
end

local function isBasePart(instance)
	local ok, result = pcall(function()
		return instance:IsA("BasePart")
	end)
	return ok and result == true
end

-- deps:
--   Signal
--   Detection: ZoneDetection
--   getPlayers: () -> {Player}
--   getRootPosition: (Player) -> Vector3?   must not yield; nil means no living character
--   canAccess: ((Player, ZoneId) -> boolean)?   future gate (e.g. rebirth-locked zones); default allows
--   warn: ((string) -> ())?

function ZoneService.new(deps)
	return setmetatable({
		_deps = deps,
		_warn = deps.warn or warn,
		
		_zonesById = {},
		_zoneByPart = {},
		_zoneList = {},
		_pendingDuplicates = {}, -- [part] = true; retried when the conflicting zone goes away
		_anchors = {}, -- [ZoneId] = {BasePart}
		_anchorZone = {}, -- [anchor part] = ZoneId
		_membership = {}, -- [Player] = ZoneId
		_population = {}, -- [ZoneId] = number
		_tieWarned = {},
		_connections = {},
		_watched = {},

		PlayerZoneChanged = deps.Signal.new(), -- (player, newZoneId?, oldZoneId?)
		ZoneAdded = deps.Signal.new(), -- (zone)
		ZoneRemoved = deps.Signal.new(), -- (zoneId)
	}, ZoneService)
end

-- Validates a tagged instance and reads its zone definition. Returns zone or nil, reason
function ZoneService.ReadZonePart(part)
	if not isBasePart(part) then
		return nil, "is not a BasePart"
	end

	local shape = "Block"
	if part:IsA("Part") then
		local shapeName = part.Shape.Name
		if shapeName == "Cylinder" then
			shape = "Cylinder"
		elseif shapeName ~= "Block" then
			return nil, `has unsupported Shape {shapeName} (use Block or Cylinder)`
		end
	end -- Other BaseParts (MeshPart, UnionOperation...) use their bounding box as a Block

	local zoneId = part:GetAttribute("ZoneId")
	if type(zoneId) ~= "string" or #zoneId == 0 or #zoneId > MAX_ZONE_ID_LENGTH then
		return nil, `needs a string ZoneId attribute of 1..{MAX_ZONE_ID_LENGTH} characters`
	end

	local priority = part:GetAttribute("Priority")
	if priority == nil then
		priority = 0
	elseif type(priority) ~= "number" or priority ~= priority then
		return nil, "has a non-numeric Priority attribute"
	end

	local verticalMode = part:GetAttribute("VerticalMode") or "Column"
	if verticalMode ~= "Column" and verticalMode ~= "Volume" then
		return nil, `has VerticalMode "{verticalMode}" (use "Column" or "Volume")`
	end

	local size = part.Size
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		return nil, "has a zero size"
	end

	local cframe = part.CFrame
	local verticalAxis = if shape == "Cylinder" then cframe.RightVector else cframe.UpVector
	if math.abs(verticalAxis.Y) < 0.999 then
		return nil,
			if shape == "Cylinder"
				then "is a Cylinder whose axis (object X) is not vertical; rotate it to stand upright"
				else "is tilted; its object Y axis must point straight up"
	end

	return {
		ZoneId = zoneId,
		Part = part,
		Shape = shape,
		VerticalMode = verticalMode,
		Priority = priority,
		CFrame = cframe,
		Size = size,
	}
end

-- Idempotent: registering the same part again returns its existing zone
function ZoneService:Register(part)
	local existing = self._zoneByPart[part]
	if existing then
		return existing
	end

	local zone, reason = ZoneService.ReadZonePart(part)
	if not zone then
		self._warn(`[ZoneService] Ignoring SpawnZone {describe(part)}: it {reason}`)
		return nil
	end

	local owner = self._zonesById[zone.ZoneId]
	if owner then
		self._pendingDuplicates[part] = true
		self._warn(
			`[ZoneService] Duplicate ZoneId "{zone.ZoneId}" on {describe(part)}; already used by {describe(owner.Part)}. `
				.. "Zone ignored until the ZoneId is unique."
		)
		return nil
	end

	self._pendingDuplicates[part] = nil
	self._zonesById[zone.ZoneId] = zone
	self._zoneByPart[part] = zone
	table.insert(self._zoneList, zone)
	self._population[zone.ZoneId] = 0
	self.ZoneAdded:Fire(zone)
	return zone
end

function ZoneService:Unregister(part)
	self._pendingDuplicates[part] = nil
	local zone = self._zoneByPart[part]
	if not zone then
		return
	end

	local zoneId = zone.ZoneId
	self._zoneByPart[part] = nil
	self._zonesById[zoneId] = nil
	local index = table.find(self._zoneList, zone)
	if index then
		table.remove(self._zoneList, index)
	end

	-- Everyone inside leaves immediately so populations and budgets stay correct
	for player, memberZoneId in table.clone(self._membership) do
		if memberZoneId == zoneId then
			self:_setMembership(player, nil)
		end
	end
	self._population[zoneId] = nil
	self.ZoneRemoved:Fire(zoneId)

	-- A part rejected as a duplicate of this one may now be valid
	for pending in table.clone(self._pendingDuplicates) do
		self._pendingDuplicates[pending] = nil
		self:Register(pending)
	end
end

function ZoneService:RegisterAnchor(part)
	self:UnregisterAnchor(part)
	if not isBasePart(part) then
		self._warn(`[ZoneService] Ignoring PickupAnchor {describe(part)}: it is not a BasePart`)
		return
	end
	local zoneId = part:GetAttribute("ZoneId")
	if type(zoneId) ~= "string" or #zoneId == 0 then
		self._warn(`[ZoneService] Ignoring PickupAnchor {describe(part)}: it needs a ZoneId attribute`)
		return
	end
	self._anchors[zoneId] = self._anchors[zoneId] or {}
	table.insert(self._anchors[zoneId], part)
	self._anchorZone[part] = zoneId
end

function ZoneService:UnregisterAnchor(part)
	local zoneId = self._anchorZone[part]
	if not zoneId then
		return
	end
	self._anchorZone[part] = nil
	local list = self._anchors[zoneId]
	local index = list and table.find(list, part)
	if index then
		table.remove(list, index)
	end
end

function ZoneService:GetAnchors(zoneId)
	return self._anchors[zoneId]
end

function ZoneService:_setMembership(player, zoneId)
	local previous = self._membership[player]
	if previous == zoneId then
		return
	end
	if previous and self._population[previous] then
		self._population[previous] -= 1
	end
	if zoneId then
		self._population[zoneId] += 1
	end
	self._membership[player] = zoneId
	self.PlayerZoneChanged:Fire(player, zoneId, previous)
end

-- One detection pass. Non-yielding: a missing character or root counts as "in no zone"
function ZoneService:Poll()
	for _, zone in self._zoneList do
		-- Zone parts may be moved at runtime; read live geometry each pass
		zone.CFrame = zone.Part.CFrame
		zone.Size = zone.Part.Size
	end

	local seen = {}
	for _, player in self._deps.getPlayers() do
		seen[player] = true
		local position = self._deps.getRootPosition(player)
		local zone, tied = self._deps.Detection.Find(position, self._zoneList)
		if tied and zone then
			local key = `{zone.ZoneId}:{zone.Priority}`
			if not self._tieWarned[key] then
				self._tieWarned[key] = true
				self._warn(
					`[ZoneService] Overlapping zones share Priority {zone.Priority} near {zone.ZoneId}. `
						.. "Give the inner zone a higher Priority."
				)
			end
		end
		self:_setMembership(player, zone and zone.ZoneId)
	end

	-- Players no longer eligible (left, or profile released) stop counting toward population
	for player in table.clone(self._membership) do
		if not seen[player] then
			self:RemovePlayer(player)
		end
	end
end

function ZoneService:RemovePlayer(player)
	self:_setMembership(player, nil)
	self._membership[player] = nil
end

function ZoneService:GetZoneOf(player)
	return self._membership[player]
end

function ZoneService:GetPopulation(zoneId)
	return self._population[zoneId] or 0
end

function ZoneService:GetZone(zoneId)
	return self._zonesById[zoneId]
end

-- Read-only view; do not mutate
function ZoneService:GetZones()
	return self._zoneList
end

-- Zone access check used by pickup validation. Removed zones are never accessible
function ZoneService:CanAccess(player, zoneId)
	if self._zonesById[zoneId] == nil then
		return false
	end
	local canAccess = self._deps.canAccess
	return canAccess == nil or canAccess(player, zoneId)
end

-- Roblox binding --------------------------------------------------------------
-- Watches a CollectionService tag. Parts outside `root` (normally Workspace) don't count;
-- attribute edits re-validate the part, removal unregisters it.
function ZoneService:BindTag(collectionService, tag, root, onAdded, onRemoved)
	local function untrack(instance)
		local connections = self._watched[instance]
		if not connections then
			return
		end
		self._watched[instance] = nil
		for _, connection in connections do
			connection:Disconnect()
		end
		onRemoved(instance)
	end

	local function track(instance)
		if self._watched[instance] then
			return
		end
		local connections = {}
		self._watched[instance] = connections

		local function sync()
			if instance:IsDescendantOf(root) then
				onAdded(instance)
			else
				onRemoved(instance)
			end
		end
		table.insert(connections, instance.AncestryChanged:Connect(sync))
		for _, attribute in WATCHED_ATTRIBUTES do
			table.insert(
				connections,
				instance:GetAttributeChangedSignal(attribute):Connect(function()
					onRemoved(instance)
					sync()
				end)
			)
		end
		sync()
	end

	table.insert(self._connections, collectionService:GetInstanceAddedSignal(tag):Connect(track))
	table.insert(self._connections, collectionService:GetInstanceRemovedSignal(tag):Connect(untrack))
	for _, instance in collectionService:GetTagged(tag) do
		track(instance)
	end
end

function ZoneService:BindCollectionService(collectionService, root)
	self:BindTag(collectionService, ZoneService.ZONE_TAG, root, function(part)
		self:Register(part)
	end, function(part)
		self:Unregister(part)
	end)
	self:BindTag(collectionService, ZoneService.ANCHOR_TAG, root, function(part)
		self:RegisterAnchor(part)
	end, function(part)
		self:UnregisterAnchor(part)
	end)
end

function ZoneService:Destroy()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	for _, connections in self._watched do
		for _, connection in connections do
			connection:Disconnect()
		end
	end
	table.clear(self._watched)
	for _, zone in table.clone(self._zoneList) do
		self:Unregister(zone.Part)
	end
	self.PlayerZoneChanged:DisconnectAll()
	self.ZoneAdded:DisconnectAll()
	self.ZoneRemoved:DisconnectAll()
end

return ZoneService
