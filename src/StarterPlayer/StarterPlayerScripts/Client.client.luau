--Responsibility: Client composition root. Loads dependencies, registers network listeners, starts the egg and target
--visuals, the temporary target click input, and the HUD, then asks the server for this player's eggs.
--Rendering and state logic live in the feature modules.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Networker = require(ReplicatedStorage.Shared.Networker.Client)
local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)

local ItemDefinitions = require(ReplicatedStorage.Shared.Configs.ItemDefintions)
local InventoryConfig = require(ReplicatedStorage.Shared.Configs.InventoryConfig)
local InventoryState = require(ReplicatedStorage.Shared.Features.Inventory.InventoryState)
local SpawningVisuals = require(ReplicatedStorage.Shared.Features.Visuals.SpawningVisuals)
local PickupVisuals = require(ReplicatedStorage.Shared.Features.Visuals.PickupVisuals)
local TargetVisuals = require(ReplicatedStorage.Shared.Features.Visuals.TargetVisuals)
local InventoryHud = require(ReplicatedStorage.Assets.UI.InventoryHud)

local TEMPLATE_WAIT_SECONDS = 10

local localPlayer = Players.LocalPlayer

--=====================================================================
-- No Reset Character in the Roblox menu. Other deaths are handled normally by the server.
-- SetCore can fail until the CoreScripts register it, so retry briefly
task.spawn(function()
	for _ = 1, 20 do
		if pcall(StarterGui.SetCore, StarterGui, "ResetButtonCallback", false) then
			return
		end
		task.wait(0.5)
	end
	warn("[Client] Couldn't disable the Reset Character button")
end)

--=====================================================================
-- Inventory (display copy; server is authoritative)

local inventoryState = InventoryState.new(InventoryConfig.MAX_STACK)

Networker.InventorySnapshot.On(function(snapshot)
	inventoryState:ApplySnapshot(snapshot)
end)
Networker.InventoryChanged.On(function(change)
	inventoryState:ApplyChange(change)
end)

local fullListeners = {}
Networker.InventoryFull.On(function(payload)
	for _, listener in table.clone(fullListeners) do
		listener(payload.ItemTypeId)
	end
end)

local function subscribeFull(listener)
	table.insert(fullListeners, listener)
	return function()
		local index = table.find(fullListeners, listener)
		if index then
			table.remove(fullListeners, index)
		end
	end
end

--=====================================================================
-- Eggs (this player's own, rendered locally)

local function waitForPath(root, names)
	local current = root
	for _, name in names do
		current = current and current:WaitForChild(name, TEMPLATE_WAIT_SECONDS)
	end
	return current
end

local templateFolder = waitForPath(ReplicatedStorage, { "Assets", "Eggs", "PickUps" })
if not templateFolder then
	warn("[Client] ReplicatedStorage.Assets.Eggs.PickUps not found; eggs will be invisible")
end

local localEggs = Instance.new("Folder")
localEggs.Name = "LocalEggs" -- created by this client, so it never replicates
localEggs.Parent = workspace

PickupVisuals.start(ItemDefinitions)
local spawning = SpawningVisuals.new({
	itemCatalog = ItemDefinitions,
	getTemplate = function(modelName)
		local template = templateFolder and templateFolder:FindFirstChild(modelName)
		return if template and (template:IsA("Model") or template:IsA("BasePart")) then template else nil
	end,
	parent = localEggs,
	onAdded = PickupVisuals.track,
	onRemoved = PickupVisuals.untrack,
	-- Post-launch polish, not wired for launch: the React rolling-digit timer (Assets/UI/EggBillboard). To enable:
	-- decorate = function(egg, entry)
	-- 	return EggBillboard.mount(egg, os.clock() + entry.RemainingLifetime)
	-- end,
})

local triggerRadius = nil -- from the snapshot; no requests before it arrives

Networker.EggSnapshot.On(function(snapshot)
	triggerRadius = snapshot.TriggerRadius
	spawning:ApplySnapshot(snapshot.Eggs)
end)
Networker.EggSpawned.On(function(record)
	spawning:Spawn(record)
end)
Networker.EggRemoved.On(function(removal)
	spawning:Remove(removal.PickupId, removal.Reason)
end)

local function requestCollect(entry)
	Networker.CollectEgg.Fire({ PickupId = entry.PickupId })
end

RunService.Heartbeat:Connect(function()
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if triggerRadius and root then
		spawning:UpdateProximity(root.Position, triggerRadius, requestCollect)
	end
end)

--=====================================================================
-- Targets (server models everyone sees; this client only decides how they look to this player)

local targetVisuals = TargetVisuals.new({
	localUserId = localPlayer.UserId,
	getServerTime = function()
		return workspace:GetServerTimeNow()
	end,
	onShown = function(targetId)
		Networker.TargetShown.Fire({ TargetId = targetId })
	end,
	showOwnerHud = true, -- temporary time/health readout until target UI is designed
})
Networker.TargetStatus.On(function(status)
	targetVisuals:SetStatus(status)
end)
task.spawn(function()
	-- The server creates Workspace.Targets at startup; don't hold up the egg snapshot request below
	targetVisuals:Attach(workspace:WaitForChild("Targets"))
end)

-- TEMPORARY pseudo-throw until real throwing exists: a click on a target the player may hit sends its TargetId.
-- Consumes nothing; the server decides claim vs damage and the damage amount
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local folder = targetVisuals:GetFolder()
	local camera = workspace.CurrentCamera
	if not folder or not camera then
		return
	end
	local ray = camera:ScreenPointToRay(input.Position.X, input.Position.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder }
	local result = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	local targetId = result and targetVisuals:ResolveTargetId(result.Instance)
	if targetId then
		Networker.HitTarget.Fire({ TargetId = targetId })
	end
end)

--=====================================================================
-- UI (appearance is being reworked separately)

local playerGui = localPlayer:WaitForChild("PlayerGui")
local root = ReactRoblox.createRoot(Instance.new("Folder"))

--[[
root:render(ReactRoblox.createPortal(
	React.createElement(InventoryHud, {
		inventoryState = inventoryState,
		itemDefinitions = ItemDefinitions,
		subscribeFull = subscribeFull,
	}),
	playerGui
))
]]

--=====================================================================
-- Every listener is registered: ask for this player's eggs
Networker.RequestEggSnapshot.Fire(0)
