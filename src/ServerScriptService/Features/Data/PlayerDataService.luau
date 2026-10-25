-- Responsibility: The shared player-data readiness contract.
-- Every feature that reads or mutates saved data asks IsActive / GetData here first.
-- Fails closed: if a profile can't load, the player is kicked with a rejoin message.
-- There is no blank fallback save, so gameplay never runs on data that won't persist.

local PlayerDataService = {}
PlayerDataService.__index = PlayerDataService

PlayerDataService.LOAD_FAILED_MESSAGE = "Your data couldn't be loaded. Please rejoin."
PlayerDataService.SESSION_ENDED_MESSAGE = "Your data session ended (you may have joined another server). Please rejoin."

-- deps:
--   Signal
--   startSession: (Player) -> Profile?   may yield; Profile = { Data, IsActive(), EndSession(), OnSessionEnd }
--   isPresent: (Player) -> boolean
--   kick: (Player, string) -> ()
--   warn: ((string) -> ())?
function PlayerDataService.new(deps)
	return setmetatable({
		_deps = deps,
		_warn = deps.warn or warn,
		_profiles = {}, -- [Player] = Profile
		_loading = {},

		Ready = deps.Signal.new(), -- (player, data)
		Releasing = deps.Signal.new(), -- (player); fired before the session ends
	}, PlayerDataService)
end

-- Yields. Call on its own thread per joining player
function PlayerDataService:LoadAsync(player)
	if self._profiles[player] or self._loading[player] then
		return
	end
	self._loading[player] = true
	local ok, profileOrError = pcall(self._deps.startSession, player)
	self._loading[player] = nil

	if not ok or profileOrError == nil then
		if not ok then
			self._warn(`[PlayerDataService] Profile load failed for {player.UserId}: {profileOrError}`)
		end
		if self._deps.isPresent(player) then
			self._deps.kick(player, PlayerDataService.LOAD_FAILED_MESSAGE)
		end
		return
	end

	local profile = profileOrError
	if not self._deps.isPresent(player) then
		-- Left while loading
		profile:EndSession()
		return
	end

	self._profiles[player] = profile
	profile.OnSessionEnd:Connect(function()
		if self._profiles[player] ~= profile then
			return
		end
		self._profiles[player] = nil
		self.Releasing:Fire(player)
		if self._deps.isPresent(player) then
			self._deps.kick(player, PlayerDataService.SESSION_ENDED_MESSAGE)
		end
	end)
	self.Ready:Fire(player, profile.Data)
end

-- True only while the player's profile is loaded and its session lock is held
function PlayerDataService:IsActive(player)
	local profile = self._profiles[player]
	return profile ~= nil and profile:IsActive()
end

-- Live saved data, or nil when not active. Mutate only without yielding between check and write
function PlayerDataService:GetData(player)
	local profile = self._profiles[player]
	if profile and profile:IsActive() then
		return profile.Data
	end
	return nil
end

function PlayerDataService:Release(player)
	local profile = self._profiles[player]
	if not profile then
		return
	end
	self._profiles[player] = nil
	self.Releasing:Fire(player)
	profile:EndSession()
end

return PlayerDataService
