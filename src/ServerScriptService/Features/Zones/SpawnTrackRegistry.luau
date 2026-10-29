-- Responsibility: Personal, per-player spawning sessions (tutorial and other scripted sequences).
-- Ordinary floor supply is scheduled per zone by ZoneSpawner, never per player, so it cannot multiply with
-- player count. This registry only holds work that belongs to exactly one player.
--
-- Sessions are keyed by (UserId, key). Opening a key that is already open closes the old session first,
-- so a session is never overwritten without cleanup. Respawning doesn't touch sessions (they aren't tied
-- to the character), and EggService closes them all on PlayerRemoving.

local SpawnTrackRegistry = {}
SpawnTrackRegistry.__index = SpawnTrackRegistry

local Session = {}
Session.__index = Session

-- Cleanup runs when the session closes, in reverse order of registration
function Session:AddCleanup(cleanup)
	if not self.Active then
		cleanup()
		return
	end
	table.insert(self._cleanups, cleanup)
end

-- deps: spawn: (fn, ...) -> thread, cancel: (thread) -> (), warn: ((string) -> ())?
function SpawnTrackRegistry.new(deps)
	return setmetatable({
		_spawn = deps.spawn,
		_cancel = deps.cancel,
		_warn = deps.warn or warn,
		_sessions = {}, -- [UserId] = { [key] = Session }
	}, SpawnTrackRegistry)
end

-- run(session) starts on its own thread. Check session.Active after any yield
function SpawnTrackRegistry:Open(player, key, run)
	self:Close(player, key)

	local session = setmetatable({
		Player = player,
		UserId = player.UserId,
		Key = key,
		Active = true,
		Thread = nil,
		_cleanups = {},
	}, Session)

	local byKey = self._sessions[player.UserId]
	if not byKey then
		byKey = {}
		self._sessions[player.UserId] = byKey
	end
	byKey[key] = session
	session.Thread = self._spawn(run, session)
	return session
end

function SpawnTrackRegistry:Get(player, key)
	local byKey = self._sessions[player.UserId]
	return byKey and byKey[key]
end

function SpawnTrackRegistry:Close(player, key)
	local byKey = self._sessions[player.UserId]
	local session = byKey and byKey[key]
	if not session then
		return false
	end

	byKey[key] = nil
	if next(byKey) == nil then
		self._sessions[player.UserId] = nil
	end

	session.Active = false
	local thread = session.Thread
	if thread and thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then
		self._cancel(thread)
	end
	for index = #session._cleanups, 1, -1 do
		local ok, err = pcall(session._cleanups[index])
		if not ok then
			self._warn(`[SpawnTrackRegistry] Cleanup for session "{key}" failed: {err}`)
		end
	end
	table.clear(session._cleanups)
	return true
end

function SpawnTrackRegistry:CloseAll(player)
	local byKey = self._sessions[player.UserId]
	if not byKey then
		return
	end
	for key in table.clone(byKey) do
		self:Close(player, key)
	end
end

function SpawnTrackRegistry:CountFor(player)
	local count = 0
	for _ in self._sessions[player.UserId] or {} do
		count += 1
	end
	return count
end

function SpawnTrackRegistry:Destroy()
	for _, byKey in table.clone(self._sessions) do
		for key, session in table.clone(byKey) do
			self:Close(session.Player, key)
		end
	end
end

return SpawnTrackRegistry
