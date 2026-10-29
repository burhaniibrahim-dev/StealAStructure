-- Responsibility: Client-side copy of the local player's inventory, guarded by server revisions.
-- A snapshot or change is applied only if it is newer than what's held, so a stale message can never
-- overwrite a newer balance. Display only: the server stays authoritative. Pure, no Roblox services.

local InventoryState = {}
InventoryState.__index = InventoryState

function InventoryState.new(maxStack)
	return setmetatable({
		Revision = -1,
		MaxStack = maxStack,
		Counts = {},
		_listeners = {},
	}, InventoryState)
end

function InventoryState:_emit()
	for _, listener in table.clone(self._listeners) do
		listener()
	end
end

-- Equal revision is accepted so a resent snapshot is harmless
function InventoryState:ApplySnapshot(snapshot)
	if snapshot.Revision < self.Revision then
		return false
	end
	self.Revision = snapshot.Revision
	self.MaxStack = snapshot.MaxStack
	self.Counts = table.clone(snapshot.Counts)
	self:_emit()
	return true
end

function InventoryState:ApplyChange(change)
	if change.Revision <= self.Revision then
		return false
	end
	self.Revision = change.Revision
	self.Counts[change.ItemTypeId] = change.Count
	self:_emit()
	return true
end

function InventoryState:GetCount(itemTypeId)
	return self.Counts[itemTypeId] or 0
end

function InventoryState:IsFull(itemTypeId)
	return self:GetCount(itemTypeId) >= self.MaxStack
end

-- Fresh table each call so UI state comparisons see a change
function InventoryState:Get()
	return { Revision = self.Revision, MaxStack = self.MaxStack, Counts = table.clone(self.Counts) }
end

function InventoryState:Subscribe(listener)
	table.insert(self._listeners, listener)
	return function()
		local index = table.find(self._listeners, listener)
		if index then
			table.remove(self._listeners, index)
		end
	end
end

return InventoryState
