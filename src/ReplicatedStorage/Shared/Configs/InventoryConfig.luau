-- Responsibility: Shared inventory rules. The server enforces them; the client uses them only as a startup default
-- until the first InventorySnapshot arrives (snapshots carry the authoritative MaxStack).

return {
	MAX_STACK = 100, -- Maximum count per egg type. Each egg type is its own stack
}
