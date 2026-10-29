-- Responsibility: The one authoritative egg inventory. Each egg type is its own stack capped at InventoryConfig.MAX_STACK.
-- Pickups add through here and throwing will consume through here; no other module keeps balances.
-- Every mutation requires an active profile (PlayerDataService) and never yields.
--
-- Revisions: each player's session revision increases by one per mutation. Clients apply a snapshot or
-- change only if its revision is newer than what they hold, so stale updates can't overwrite balances.

local InventoryService = {}
InventoryService.__index = InventoryService

InventoryService.Reason = {
	ProfileNotActive = "ProfileNotActive",
	UnknownItem = "UnknownItem",
	InvalidAmount = "InvalidAmount",
	StackFull = "StackFull",
	Insufficient = "Insufficient",
}

local function isValidAmount(amount)
	return type(amount) == "number" and amount == amount and amount >= 1 and math.floor(amount) == amount
end

-- deps: data (PlayerDataService contract), itemCatalog (Shared ItemDefintions), maxStack (InventoryConfig.MAX_STACK), Signal
function InventoryService.new(deps)
	return setmetatable({
		_data = deps.data,
		_items = deps.itemCatalog,
		MaxStack = deps.maxStack,
		_revisions = {}, -- [Player] = number

		Changed = deps.Signal.new(), -- (player, itemTypeId, count, revision)
	}, InventoryService)
end

function InventoryService:_inventory(player)
	local data = self._data:GetData(player)
	if data == nil then
		return nil, InventoryService.Reason.ProfileNotActive
	end
	if data.Inventory == nil then
		data.Inventory = {}
	end
	return data.Inventory
end

function InventoryService:_check(player, itemTypeId, amount)
	if self._items[itemTypeId] == nil then
		return nil, InventoryService.Reason.UnknownItem
	end
	if not isValidAmount(amount) then
		return nil, InventoryService.Reason.InvalidAmount
	end
	return self:_inventory(player)
end

function InventoryService:_commit(player, inventory, itemTypeId, count)
	inventory[itemTypeId] = count
	local revision = (self._revisions[player] or 0) + 1
	self._revisions[player] = revision
	self.Changed:Fire(player, itemTypeId, count, revision)
end

function InventoryService:GetCount(player, itemTypeId)
	local inventory = self:_inventory(player)
	return inventory and inventory[itemTypeId] or 0
end

function InventoryService:GetSpace(player, itemTypeId)
	return math.max(self.MaxStack - self:GetCount(player, itemTypeId), 0)
end

function InventoryService:IsFull(player, itemTypeId)
	return self:GetCount(player, itemTypeId) >= self.MaxStack
end

-- All-or-nothing: true only if the whole amount fits
function InventoryService:CanAdd(player, itemTypeId, amount)
	local inventory, reason = self:_check(player, itemTypeId, amount)
	if not inventory then
		return false, reason
	end
	if (inventory[itemTypeId] or 0) + amount > self.MaxStack then
		return false, InventoryService.Reason.StackFull
	end
	return true
end

function InventoryService:TryAdd(player, itemTypeId, amount)
	local inventory, reason = self:_check(player, itemTypeId, amount)
	if not inventory then
		return false, reason
	end
	local count = (inventory[itemTypeId] or 0) + amount
	if count > self.MaxStack then
		return false, InventoryService.Reason.StackFull
	end
	self:_commit(player, inventory, itemTypeId, count)
	return true, count
end

function InventoryService:TryConsume(player, itemTypeId, amount)
	local inventory, reason = self:_check(player, itemTypeId, amount)
	if not inventory then
		return false, reason
	end
	local current = inventory[itemTypeId] or 0
	if current < amount then
		return false, InventoryService.Reason.Insufficient
	end
	self:_commit(player, inventory, itemTypeId, current - amount)
	return true, current - amount
end

function InventoryService:GetRevision(player)
	return self._revisions[player] or 0
end

-- Snapshot of known egg types only; unknown saved keys (removed egg types) are left untouched in the save
function InventoryService:GetSnapshot(player)
	local inventory = self:_inventory(player)
	if not inventory then
		return nil
	end
	local counts = {}
	for itemTypeId in self._items do
		counts[itemTypeId] = inventory[itemTypeId] or 0
	end
	return { Revision = self:GetRevision(player), MaxStack = self.MaxStack, Counts = counts }
end

function InventoryService:ClearSession(player)
	self._revisions[player] = nil
end

return InventoryService
