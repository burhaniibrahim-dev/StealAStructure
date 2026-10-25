-- Responsibility: Roblox-side adapters for the pickup system. Ground raycasts, obstruction checks, character
-- lookup, and the server-owned pickup models that replicate through Workspace.
-- Pure modules (PickupPlacement, ItemService) only see the small interfaces built here.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Janitor = require(ReplicatedStorage.Packages.Janitor)

local RobloxPickupWorld = {}

-- Surfaces tagged (or with attribute) NoPickupSpawn never receive pickups
RobloxPickupWorld.BLOCKED_TAG = "NoPickupSpawn"

-- Non-yielding. nil unless the player has a living character with a HumanoidRootPart
function RobloxPickupWorld.getRootPosition(player)
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	return root.Position
end

function RobloxPickupWorld.isPlayerPresent(player)
	return player.Parent == Players
end

local function getCharacters()
	local characters = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(characters, player.Character)
		end
	end
	return characters
end

-- options: { workspace, pickupFolder, zoneTag }
function RobloxPickupWorld.newWorld(options)
	local world = options.workspace

	local function ignoredInstances()
		local ignored = getCharacters()
		table.insert(ignored, options.pickupFolder)
		for _, zonePart in CollectionService:GetTagged(options.zoneTag) do
			table.insert(ignored, zonePart)
		end
		return ignored
	end

	local adapter = {}

	function adapter:Raycast(origin, direction)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = ignoredInstances()
		params.IgnoreWater = false -- water must be hit so ForbiddenMaterials can reject it

		local result = world:Raycast(origin, direction, params)
		if not result then
			return nil
		end
		local hitInstance = result.Instance
		return {
			Position = result.Position,
			Normal = result.Normal,
			Distance = result.Distance,
			Material = result.Material.Name,
			Instance = hitInstance,
			Blocked = hitInstance:GetAttribute(RobloxPickupWorld.BLOCKED_TAG) == true
				or CollectionService:HasTag(hitInstance, RobloxPickupWorld.BLOCKED_TAG),
		}
	end

	function adapter:GetCharacterPositions()
		local positions = {}
		for _, player in Players:GetPlayers() do
			local position = RobloxPickupWorld.getRootPosition(player)
			if position then
				table.insert(positions, position)
			end
		end
		return positions
	end

	function adapter:IsSpaceBlocked(position, radius, ground)
		if radius <= 0 then
			return false
		end
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local ignored = ignoredInstances()
		table.insert(ignored, world.Terrain)
		if ground then
			table.insert(ignored, ground)
		end
		params.FilterDescendantsInstances = ignored
		for _, part in world:GetPartBoundsInRadius(position, radius, params) do
			if part.CanCollide then
				return true
			end
		end
		return false
	end

	return adapter
end

local function makeFallbackVisual(definition)
	local egg = Instance.new("Part")
	egg.Name = "Visual"
	egg.Size = Vector3.new(1.4, 1.8, 1.4)
	egg.Color = definition.Color
	egg.Material = Enum.Material.SmoothPlastic
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = egg
	return egg
end

local function makeVisual(definition, templates)
	local template = templates and templates:FindFirstChild(definition.ModelName)
	if template and (template:IsA("BasePart") or template:IsA("Model")) then
		local visual = template:Clone()
		visual.Name = "Visual"
		return visual
	end
	return makeFallbackVisual(definition)
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

-- options: { folder, itemDefinitions, templates: Instance?, pickupRadius, onTouched: (pickupId, player) -> () }
-- Returns { Create(record) -> cleanup }. Each pickup's model and touch connection belong to one Janitor.
function RobloxPickupWorld.newModelFactory(options)
	local factory = {}

	function factory.Create(record)
		local definition = options.itemDefinitions.Items[record.ItemTypeId]
		local janitor = Janitor.new()

		local model = Instance.new("Model")
		model.Name = `Pickup_{record.PickupId}`
		model:SetAttribute("PickupId", record.PickupId)
		model:SetAttribute("ItemTypeId", record.ItemTypeId)
		model:SetAttribute("Amount", record.Amount)
		if record.ReservedUserId then
			-- Clients hide pickups reserved for someone else
			model:SetAttribute("ReservedUserId", record.ReservedUserId)
		end

		local hitbox = Instance.new("Part")
		hitbox.Name = "Hitbox"
		hitbox.Shape = Enum.PartType.Ball
		hitbox.Size = Vector3.one * options.pickupRadius * 2
		hitbox.CFrame = CFrame.new(record.Position)
		hitbox.Transparency = 1
		hitbox.Anchored = true
		hitbox.CanCollide = false
		hitbox.CanQuery = false
		hitbox.CanTouch = true
		hitbox.Parent = model
		model.PrimaryPart = hitbox

		local visual = makeVisual(definition, options.templates)
		makeInert(visual)
		visual:PivotTo(CFrame.new(record.Position))
		visual.Parent = model

		janitor:Add(hitbox.Touched:Connect(function(hit)
			local character = hit:FindFirstAncestorOfClass("Model")
			local player = character and Players:GetPlayerFromCharacter(character)
			if player then
				options.onTouched(record.PickupId, player)
			end
		end), "Disconnect")
		janitor:Add(model, "Destroy")

		record.Model = model
		model.Parent = options.folder

		return function()
			record.Model = nil
			janitor:Destroy()
		end
	end

	return factory
end

return RobloxPickupWorld
