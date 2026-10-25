# Project Map

## Purpose
Roblox winter-themed shared-map PvP simulator (StealAStructure). Players collect eggs from the floor and throw them at structures, targets, and traps. Implemented feature: item spawning + floor pickup (2026-10-24, direct implementation from learner's spec).

## Requirements (from learner's spec)
- Separate stack per egg type, max 100. Walk-over collection. Floor eggs expire after configurable lifetime.
- Per-zone configurable distributions; never spawn on active traps; full inventory leaves pickup in place.
- Tutorial gate for ordinary pickups; reserved tutorial pickups may have larger amounts.
- Every inventory mutation needs an active loaded profile; client never chooses rarity/amount/position.

## Components (implemented)
- Runner.server.luau — composition root; one Heartbeat drives zone poll (0.3s), spawner + ExpireDue, proximity sweep.
- Services.luau — handles to live services for other features.
- Configs/PickupConfig (server-only rules), Configs/ConfigValidator.
- Features/Data: PlayerDataService (ProfileStore, fail closed), DataTemplate.
- Features/Inventory/InventoryService — only balance owner; revisioned.
- Features/Zones: ZoneService (stable ZoneId attribute, membership, population, anchors), ZoneDetection (pure geometry), ZoneSpawner (per-zone timers + budgets), SpawnTrackRegistry (personal tutorial sessions).
- Features/Items: ItemRegistry (records + indexes), ItemService (lifecycle, atomic collect), PickupPlacement, ExclusionProviders (NoTrapsProvider placeholder), PickupAnalytics, RobloxPickupWorld (Roblox adapters).
- Shared: Configs/Items/ItemDefinitions (presentation + MAX_STACK), Inventory/InventoryState (client revision guard).
- Client: Client.client.luau, Controllers/PickupVisuals, UI/InventoryHud (React).
- Blink events: InventorySnapshot, InventoryChanged, PickupCollected, InventoryFull (all server -> owning client, reliable).
- Tests: tests/ (Lune, `lune run tests/run`).

## Main Flow
Server poll: root position -> ZoneDetection.Find -> membership/population
ZoneSpawner (per zone, population-scaled) -> ItemService:TrySpawnOrdinary -> PickupPlacement -> ItemRegistry + server model in Workspace.Pickups
Touch or sweep (server) -> ItemService:TryCollect -> InventoryService:TryAdd -> Blink to owner

## Data and Trust Boundaries
Server owns inventory, pickup eligibility, spawn outcomes, timing. Client only renders (bob/spin, effects, HUD, hides others' reserved pickups). Clients send nothing for pickups.

## Build and Deployment
Rojo `default.project.json` (ServerPackages mapped under ServerScriptService). Toolchain `rokit.toml`; stylua/selene pinned but not trusted/installed locally as of 2026-10-24.

## Unknowns / integration dependencies
- Trap system (replace NoTrapsProvider), tutorial feature (calls ItemService tutorial API), throwing (InventoryService:TryConsume), movement validation, platform analytics sink.
