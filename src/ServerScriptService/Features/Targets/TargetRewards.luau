-- Responsibility: The reward boundary for target runs. Picks the highest bracket a score reaches and rolls one
-- weighted drop from that bracket only (lower brackets are never combined, and there is one roll per run).
-- Paying is delegated to an injected `pay` function, because reward items (eggs above the stack cap, traps, ...)
-- are not designed yet. Without one, every drop fails to pay, so no cooldown can start.
--
-- Bracket shape (TargetConfig.RewardBrackets): { MinScore: number, Drops: { { Weight: number, ...drop fields } } }

local TargetRewards = {}
TargetRewards.__index = TargetRewards

-- deps: brackets (TargetConfig.RewardBrackets), rng, pay: ((player, drop) -> (boolean, string?))?
function TargetRewards.new(deps)
	return setmetatable({
		_brackets = deps.brackets,
		_rng = deps.rng,
		_pay = deps.pay,
	}, TargetRewards)
end

local function pickWeighted(list, rng)
	local total = 0
	for _, entry in list do
		total += entry.Weight
	end
	local roll = rng:NextNumber(0, total)
	for _, entry in list do
		roll -= entry.Weight
		if roll < 0 then
			return entry
		end
	end
	return list[#list]
end

-- The highest bracket with MinScore <= score, or nil
function TargetRewards:GetBracket(score)
	local best = nil
	for _, bracket in self._brackets do
		if score >= bracket.MinScore and (best == nil or bracket.MinScore > best.MinScore) then
			best = bracket
		end
	end
	return best
end

-- One drop for this score, or nil when no bracket is reached
function TargetRewards:Resolve(score)
	local bracket = self:GetBracket(score)
	return bracket and pickWeighted(bracket.Drops, self._rng)
end

-- Returns true when the drop was delivered, otherwise false and a reason. Must not yield
function TargetRewards:Pay(player, drop)
	if not self._pay then
		return false, "NoPayout"
	end
	return self._pay(player, drop)
end

return TargetRewards
