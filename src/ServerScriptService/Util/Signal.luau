-- Responsibility: Minimal synchronous signal for server services.
-- Listeners run immediately, in connect order, on the firing thread. Listeners must not yield:
-- services fire these right after an atomic state change and keep processing afterwards

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _listeners = {} }, Signal)
end

function Signal:Connect(listener)
	local entry = { Listener = listener, Connected = true }
	table.insert(self._listeners, entry)

	local listeners = self._listeners
	return {
		Disconnect = function()
			if not entry.Connected then
				return
			end
			entry.Connected = false
			local index = table.find(listeners, entry)
			if index then
				table.remove(listeners, index)
			end
		end,
	}
end

function Signal:Fire(...)
	-- Copy so listeners can disconnect themselves while firing
	for _, entry in table.clone(self._listeners) do
		if entry.Connected then
			entry.Listener(...)
		end
	end
end

function Signal:DisconnectAll()
	for _, entry in self._listeners do
		entry.Connected = false
	end
	table.clear(self._listeners)
end

return Signal
