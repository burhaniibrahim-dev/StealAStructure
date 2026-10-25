-- Responsibility: Internal pickup analytics. Aggregates egg source totals and emits milestone events.
-- Nothing here calls a platform analytics API per spawn or per effect; a future analytics feature can
-- subscribe to Milestone and read GetSourceTotals on its own schedule. Debug logging stays elsewhere.

local PickupAnalytics = {}
PickupAnalytics.__index = PickupAnalytics

PickupAnalytics.Source = {
	Floor = "Floor",
	TutorialFloor = "TutorialFloor",
}

PickupAnalytics.Milestone = {
	FirstScriptedCollection = "FirstScriptedCollection",
	FirstOrdinaryCollection = "FirstOrdinaryCollection",
}

-- deps: data (PlayerDataService contract), Signal
function PickupAnalytics.new(deps)
	return setmetatable({
		_data = deps.data,
		_totals = {}, -- [Source] = { [ItemTypeId] = amount }

		Milestone = deps.Signal.new(), -- (player, milestoneName, record)
	}, PickupAnalytics)
end

-- Called by ItemService after a committed collection
function PickupAnalytics:RecordCollection(player, record)
	local isScripted = record.ReservedUserId ~= nil
	local source = if isScripted then PickupAnalytics.Source.TutorialFloor else PickupAnalytics.Source.Floor

	local bySource = self._totals[source]
	if not bySource then
		bySource = {}
		self._totals[source] = bySource
	end
	bySource[record.ItemTypeId] = (bySource[record.ItemTypeId] or 0) + record.Amount

	-- "First" is lifetime, so the flag lives in the profile
	local data = self._data:GetData(player)
	if not data then
		return
	end
	data.Milestones = data.Milestones or {}
	local milestone = if isScripted
		then PickupAnalytics.Milestone.FirstScriptedCollection
		else PickupAnalytics.Milestone.FirstOrdinaryCollection
	if not data.Milestones[milestone] then
		data.Milestones[milestone] = true
		self.Milestone:Fire(player, milestone, record)
	end
end

function PickupAnalytics:GetSourceTotals()
	local copy = {}
	for source, byItem in self._totals do
		copy[source] = table.clone(byItem)
	end
	return copy
end

function PickupAnalytics:ResetTotals()
	table.clear(self._totals)
end

return PickupAnalytics
