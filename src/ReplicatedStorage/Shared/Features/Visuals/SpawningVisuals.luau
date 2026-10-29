-- Responsibility: The local player's own eggs on this client. Clones authored templates into a local folder,
-- keyed by server PickupId, and destroys them on removal. Other players' eggs never reach this client.
-- Display only: the server owns every record and decides every collection.
--
-- Reconciliation (Remotes.blink sends the snapshot first, then live events in order):
--   Spawn          ignored when the PickupId is already shown or was already removed, so repeats never duplicate
--   Remove         destroys the clone and remembers the PickupId, so a late spawn can't bring it back
--   ApplySnapshot  the server's full set: anything not in it is removed, anything missing is spawned
-- Expiry is never decided here: an egg stays until the server's EggRemoved, whatever RemainingLifetime says.
--
-- Templates: ItemDefintions[ItemTypeId].ModelName, a Model or BasePart. If one can't be resolved, the egg
-- is shown with the VisualFallback egg's model (same item, same reward); if that fails too, the egg is tracked
-- without a model so later removal still works. Instance access is injected, so this module runs under Lune.
--
-- Emerging: each new egg starts buried below the ground and digs itself out, ending a little above the ground.
-- The ground comes from a client raycast below the server position; the hover gap scales with the egg's height.
-- onAdded fires once the egg has finished emerging, so idle animation (PickupVisuals) starts from its resting spot.

local SpawningVisuals = {}
SpawningVisuals.__index = SpawningVisuals

local GROUND_RAY_HEIGHT = 5 -- the ground ray starts this far above the server position
local GROUND_RAY_DEPTH = 10 -- and searches this far below it
local ZONE_TAG = "SpawnZone" -- zone parts float above the ground, so the ground ray passes through them (ZoneService.ZONE_TAG)
local MEASURE_PART_NAME = "Root" -- the part of an egg Model whose size sets the resting height (ignores Hitbox etc.)
local HOVER_RATIO = 0.05 -- resting gap under the egg, as a fraction of the egg's height
local EMERGE_TIME = 0.6 -- seconds to dig out
local EMERGE_SHAKE_DEGREES = 12 -- side-to-side wobble while digging, fading out as it rises
local EMERGE_SHAKES = 3 -- wobble cycles over the whole dig

SpawningVisuals.HOVER_RATIO = HOVER_RATIO -- read-only; exposed so tests follow the tuned value

-- Height and bottom of one part in world space, accounting for its rotation
local function measurePart(part)
	local cframe, size = part.CFrame, part.Size
	local up = Vector3.yAxis
	local height = math.abs(cframe.RightVector:Dot(up)) * size.X
		+ math.abs(cframe.UpVector:Dot(up)) * size.Y
		+ math.abs(cframe.LookVector:Dot(up)) * size.Z
	return height, cframe.Position.Y - height / 2
end

-- Height and bottom of the visible egg. A Model is measured by its MEASURE_PART_NAME child (the egg mesh), so
-- helpers like the Hitbox don't count; without one, the whole bounding box is used
local function measure(instance)
	if instance:IsA("BasePart") then
		return measurePart(instance)
	end
	local root = instance:FindFirstChild(MEASURE_PART_NAME)
	if root and root:IsA("BasePart") then
		return measurePart(root)
	end
	local center, size = instance:GetBoundingBox()
	return size.Y, center.Position.Y - size.Y / 2
end

-- Roblox default: ground Y below `position`, ignoring local eggs, every character, and zone parts. nil when nothing is hit
local function robloxFindGroundY(position, ignore)
	local CollectionService = game:GetService("CollectionService")
	local Players = game:GetService("Players")
	local ignored = { ignore }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignored, player.Character)
		end
	end
	for _, zonePart in CollectionService:GetTagged(ZONE_TAG) do
		table.insert(ignored, zonePart)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignored
	local origin = position + Vector3.new(0, GROUND_RAY_HEIGHT, 0)
	local result = workspace:Raycast(origin, Vector3.new(0, -(GROUND_RAY_HEIGHT + GROUND_RAY_DEPTH), 0), params)
	return result and result.Position.Y
end

-- Roblox default: dig `instance` from `from` to `to`, then call onDone. Returns a cancel function
local function robloxPlayEmerge(instance, from, to, onDone)
	local RunService = game:GetService("RunService")
	local TweenService = game:GetService("TweenService")
	local elapsed = 0
	local connection
	connection = RunService.RenderStepped:Connect(function(deltaTime)
		elapsed = math.min(elapsed + deltaTime, EMERGE_TIME)
		local alpha = elapsed / EMERGE_TIME
		local rise = TweenService:GetValue(alpha, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		local shake = math.sin(alpha * EMERGE_SHAKES * 2 * math.pi) * math.rad(EMERGE_SHAKE_DEGREES) * (1 - alpha)
		instance:PivotTo(from:Lerp(to, rise) * CFrame.Angles(0, 0, shake))
		if alpha >= 1 then
			connection:Disconnect()
			instance:PivotTo(to)
			onDone()
		end
	end)
	return function()
		connection:Disconnect()
	end
end

local function findFallback(catalog)
	for itemTypeId, definition in catalog do
		if definition.VisualFallback == true then
			return itemTypeId
		end
	end
	return nil
end

local function makeInert(instance)
	local parts = if instance:IsA("BasePart") then { instance } else {}
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	for _, part in parts do
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
	end
end

-- deps:
--   itemCatalog   Shared ItemDefintions
--   getTemplate   (modelName) -> Instance?   a Model or BasePart, or nil when it doesn't exist
--   parent        Instance                    local folder the clones go in
--   onAdded       ((entry) -> ())?            after an egg has finished emerging (entry.Instance may be nil)
--   onRemoved     ((entry, reason) -> ())?    after an egg's model is destroyed
--   findGroundY   ((position, ignore) -> number?)?          defaults to a client raycast
--   playEmerge    ((instance, from, to, onDone) -> cancel)?  defaults to the dig-out animation
--   decorate      ((instance, entry) -> cleanup?)?           extra per-egg UI (EggBillboard); cleanup runs on removal
--   warn          ((string) -> ())?
function SpawningVisuals.new(deps)
	return setmetatable({
		_items = deps.itemCatalog,
		_fallbackItemTypeId = findFallback(deps.itemCatalog),
		_getTemplate = deps.getTemplate,
		_findGroundY = deps.findGroundY or robloxFindGroundY,
		_playEmerge = deps.playEmerge or robloxPlayEmerge,
		_decorate = deps.decorate,
		_parent = deps.parent,
		_onAdded = deps.onAdded,
		_onRemoved = deps.onRemoved,
		_warn = deps.warn or warn,
		_entries = {}, -- [PickupId] = entry
		_removed = {}, -- [PickupId] = true; PickupIds are never reused
	}, SpawningVisuals)
end

function SpawningVisuals:_resolveTemplate(itemTypeId)
	local definition = self._items[itemTypeId]
	if definition then
		local template = self._getTemplate(definition.ModelName)
		if template then
			return template
		end
	end
	local modelName = if definition then definition.ModelName else `<unknown item {itemTypeId}>`
	local fallbackId = self._fallbackItemTypeId
	local fallbackModel = fallbackId and self._items[fallbackId].ModelName
	local fallback = fallbackModel and self._getTemplate(fallbackModel)
	if fallback then
		self._warn(`MODEL OF {modelName} doesnt exist (item {itemTypeId}); showing {fallbackModel} ({fallbackId}) instead`)
		return fallback
	end
	self._warn(`MODEL OF {modelName} doesnt exist (item {itemTypeId}); no fallback model either, egg {itemTypeId} is invisible`)
	return nil
end

-- data: EggRecord from Remotes.blink. Returns the new entry, or nil when it was a repeat or already removed
function SpawningVisuals:Spawn(data)
	local pickupId = data.PickupId
	if self._entries[pickupId] or self._removed[pickupId] then
		return nil
	end

	local entry = {
		PickupId = pickupId,
		ItemTypeId = data.ItemTypeId,
		Amount = data.Amount,
		ZoneId = data.ZoneId,
		Position = data.Position,
		RemainingLifetime = data.RemainingLifetime,
		Instance = nil,
		InRange = false,
		CancelEmerge = nil,
		CleanupDecoration = nil,
	}
	self._entries[pickupId] = entry

	local template = self:_resolveTemplate(data.ItemTypeId)
	if not template then
		self:_finishEmerge(entry)
		return entry
	end

	local clone = template:Clone()
	clone.Name = `Egg_{pickupId}`
	makeInert(clone)
	clone:PivotTo(CFrame.new(data.Position))

	-- Rest the egg's bottom a size-scaled gap above the ground the client sees. Without ground, the server position
	-- is the bottom
	local height, bottomY = measure(clone)
	local groundY = self._findGroundY(data.Position, self._parent) or data.Position.Y
	local gap = height * HOVER_RATIO
	local rest = CFrame.new(data.Position + Vector3.new(0, groundY + gap - bottomY, 0))
	local buried = rest - Vector3.new(0, height + gap, 0) -- top level with the ground

	clone:PivotTo(buried)
	clone.Parent = self._parent
	entry.Instance = clone
	if self._decorate then
		entry.CleanupDecoration = self._decorate(clone, entry)
	end
	local finished = false
	local cancel = self._playEmerge(clone, buried, rest, function()
		finished = true
		entry.CancelEmerge = nil
		self:_finishEmerge(entry)
	end)
	if not finished then
		entry.CancelEmerge = cancel
	end
	return entry
end

function SpawningVisuals:_finishEmerge(entry)
	-- Removed while still digging: nothing to hand on
	if self._entries[entry.PickupId] ~= entry then
		return
	end
	if self._onAdded then
		self._onAdded(entry)
	end
end

-- Returns the removed entry, or nil when it wasn't shown
function SpawningVisuals:Remove(pickupId, reason)
	self._removed[pickupId] = true
	local entry = self._entries[pickupId]
	if not entry then
		return nil
	end
	self._entries[pickupId] = nil
	if entry.CancelEmerge then
		entry.CancelEmerge()
		entry.CancelEmerge = nil
	end
	if entry.CleanupDecoration then
		entry.CleanupDecoration()
		entry.CleanupDecoration = nil
	end
	if entry.Instance then
		entry.Instance:Destroy()
		entry.Instance = nil
	end
	if self._onRemoved then
		self._onRemoved(entry, reason)
	end
	return entry
end

-- records: the server's complete list of this player's eggs
function SpawningVisuals:ApplySnapshot(records)
	local keep = {}
	for _, data in records do
		keep[data.PickupId] = true
	end
	for pickupId in table.clone(self._entries) do
		if not keep[pickupId] then
			self:Remove(pickupId, "Snapshot")
		end
	end
	for _, data in records do
		-- The snapshot is server truth: an id in it is live even if this client marked it removed
		self._removed[data.PickupId] = nil
		self:Spawn(data)
	end
end

function SpawningVisuals:Get(pickupId)
	return self._entries[pickupId]
end

function SpawningVisuals:Count()
	local count = 0
	for _ in self._entries do
		count += 1
	end
	return count
end

-- Calls onEnter(entry) once each time an egg comes within `radius` of `position`. It won't fire again for that
-- egg until it leaves the radius and comes back, so a rejected request (for example a full stack) isn't retried
-- while the player stands still
function SpawningVisuals:UpdateProximity(position, radius, onEnter)
	for _, entry in self._entries do
		local inRange = (entry.Position - position).Magnitude <= radius
		if inRange and not entry.InRange then
			entry.InRange = true
			onEnter(entry)
		elseif not inRange then
			entry.InRange = false
		end
	end
end

function SpawningVisuals:Destroy()
	for pickupId in table.clone(self._entries) do
		self:Remove(pickupId, "Destroyed")
	end
end

return SpawningVisuals
