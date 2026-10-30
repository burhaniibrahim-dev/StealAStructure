-- Responsibility: Roblox-side adapters for the egg system. Ground raycasts, obstruction checks, character
-- positions, and the authored template lookup. The server never builds egg models: each owner's client clones
-- its own from ReplicatedStorage.Assets.Eggs.PickUps.
-- Pure modules (PickupPlacement, EggService, ZoneSpawner) only see the small interfaces built here.
-- General player/character lookups live in Features/Util/RobloxPlayers.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local RobloxPlayers = require(ServerScriptService.Features.Util.RobloxPlayers)

local RobloxPickupWorld = {}

-- Surfaces tagged (or with attribute) NoPickupSpawn never receive pickups
RobloxPickupWorld.BLOCKED_TAG = "NoPickupSpawn"

local function getCharacters()
	local characters = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(characters, player.Character)
		end
	end
	return characters
end

-- options: { workspace, zoneTag, ignore: { Instance }? }   ignore: extra instances rays and overlap checks skip
function RobloxPickupWorld.newWorld(options)
	local world = options.workspace

	local function ignoredInstances()
		local ignored = getCharacters()
		for _, zonePart in CollectionService:GetTagged(options.zoneTag) do
			table.insert(ignored, zonePart)
		end
		for _, instance in options.ignore or {} do
			table.insert(ignored, instance)
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
			local position = RobloxPlayers.getRootPosition(player)
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

-- Authored pickup templates: ReplicatedStorage.Assets.Eggs.PickUps.<ModelName>, a Model or a BasePart.
-- Looked up live on every call, so a template removed at runtime is noticed on the next spawn attempt.
-- Returns { Has: (modelName) -> boolean }
function RobloxPickupWorld.newTemplateLookup(replicatedStorage)
	local function folder()
		local assets = replicatedStorage:FindFirstChild("Assets")
		local eggs = assets and assets:FindFirstChild("Eggs")
		return eggs and eggs:FindFirstChild("PickUps")
	end

	local lookup = {}
	function lookup.Has(modelName)
		local pickUps = folder()
		local template = pickUps and pickUps:FindFirstChild(modelName)
		return template ~= nil and (template:IsA("Model") or template:IsA("BasePart"))
	end
	return lookup
end

return RobloxPickupWorld
