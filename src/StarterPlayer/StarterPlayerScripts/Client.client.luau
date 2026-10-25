--Responsibility: Startup Client Functions
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Networker = require(ReplicatedStorage.Shared.Networker.Client)
local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)

local ItemDefinitions = require(ReplicatedStorage.Shared.Configs.Items.ItemDefinitions)
local InventoryState = require(ReplicatedStorage.Shared.Inventory.InventoryState)

-----------------------------------------------------------
local player = game.Players.LocalPlayer
local playerScripts = player:WaitForChild("PlayerScripts")

local PickupVisuals = require(playerScripts:WaitForChild("Controllers").PickupVisuals)
local InventoryHud = require(playerScripts.UI.InventoryHud)
------------------------------------------------------------

--=====================================================================
-- Inventory (display copy; server is authoritative)

local inventoryState = InventoryState.new(ItemDefinitions.MAX_STACK)

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
-- UI and visuals

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local root = ReactRoblox.createRoot(Instance.new("Folder"))
root:render(ReactRoblox.createPortal(
	React.createElement(InventoryHud, {
		inventoryState = inventoryState,
		itemDefinitions = ItemDefinitions,
		subscribeFull = subscribeFull,
	}),
	playerGui
))

PickupVisuals.start(Networker, ItemDefinitions)
