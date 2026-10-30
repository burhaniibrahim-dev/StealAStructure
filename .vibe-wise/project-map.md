# Project Map

## Purpose
Roblox winter-themed shared-map PvP simulator (StealAStructure). Players collect eggs from the floor and throw them at structures, targets, and traps. Implemented feature: item spawning + floor pickup (2026-10-24, direct implementation from learner's spec).

## Requirements (from learner's spec)
- Separate stack per egg type, max 100. Walk-over collection. Floor eggs expire after configurable lifetime.
- Per-zone configurable distributions; never spawn on active traps; full inventory leaves pickup in place.
- Tutorial gate for ordinary pickups; reserved tutorial pickups may have larger amounts.
- Every inventory mutation needs an active loaded profile; client never chooses rarity/amount/position.

## Components (implemented)
- Runner (Script, on disk Runner/init.server.luau) — composition root: init order, shared instances (EggRegistry, Random), the single InventoryService, Services publication, wiring, player lifecycle, zone tag binding, one Heartbeat (zone poll 0.3s, ExpireDue + spawner step, proximity sweep), debug log, shutdown.
  - Child setup ModuleScripts: Runner.Data (-> Data._Players builds ProfileStore adapter + PlayerDataService), Runner.Zones (Init -> ZoneService; StartSpawner -> ZoneSpawner, after eggs), Runner.Eggs (pickup folder, placement, exclusions, Roblox adapters, tracks, EggService).
- Services.luau — handles to live services for other features: PlayerData, Inventory, Zones, Eggs.
- Configs/PickupConfig (server-only rules), Configs/ConfigValidator.
- Features/Data: PlayerDataService (ProfileStore, fail closed), DataTemplate.
- Features/Inventory/InventoryService — only balance owner; revisioned.
- Features/Zones: ZoneService (stable ZoneId attribute, membership, population, anchors), ZoneDetection (pure geometry), ZoneSpawner (per-zone timers + budgets), SpawnTrackRegistry (personal tutorial sessions).
- Features/Items/Eggs: EggRegistry (records + indexes), EggService (floor egg lifecycle, atomic collect), PickupPlacement, ExclusionProviders (NoTrapsProvider placeholder), RobloxPickupWorld (Roblox adapters), PickupAnalytics (deferred, inactive).
- Features/Items/Tools: empty placeholder for troll tools (bear traps etc.); nothing implemented.
- Util: Signal, RobloxPlayers (getRootPosition, isPlayerPresent; shared by data, zones, eggs).
- Shared: Configs/Items/ItemDefinitions (presentation + MAX_STACK), Inventory/InventoryState (client revision guard).
- Client: Client.client.luau, Controllers/PickupVisuals, UI/InventoryHud (React).
- Blink events: InventorySnapshot, InventoryChanged, PickupCollected, InventoryFull (all server -> owning client, reliable).
- Tests: tests/ (Lune, `lune run tests/run`).

## Main Flow
Server poll: root position -> ZoneDetection.Find -> membership/population
ZoneSpawner (per zone, population-scaled) -> EggService:TrySpawnOrdinary -> PickupPlacement -> EggRegistry + server model in Workspace.Pickups
Touch or sweep (server) -> EggService:TryCollect -> InventoryService:TryAdd -> Blink to owner

## Data and Trust Boundaries
Server owns inventory, pickup eligibility, spawn outcomes, timing. Client only renders (bob/spin, effects, HUD, hides others' reserved pickups). Clients send nothing for pickups.

## Build and Deployment
Rojo `default.project.json` (ServerPackages mapped under ServerScriptService). Toolchain `rokit.toml`; stylua/selene pinned but not trusted/installed locally as of 2026-10-24.

## Unknowns / integration dependencies
- Trap system (replace NoTrapsProvider), tutorial feature (calls EggService tutorial API via Services.Eggs), throwing (InventoryService:TryConsume), movement validation, platform analytics sink.

## Post-MVP: pickup analytics (deferred, 2026-10-26)
- Status: retained but inactive. Module: src/ServerScriptService/Features/Items/Eggs/PickupAnalytics.luau. Nothing requires or constructs it at runtime; not published in Services.
- What it tracks: server-wide (not per-player) collection totals by source (Floor / TutorialFloor) and egg type; first ordinary and first scripted collection per player, stored as profile flags Milestones.FirstOrdinaryCollection / FirstScriptedCollection (fields kept in DataTemplate, no migration); a Milestone signal.
- Integration removed from: EggService:TryCollect (the RecordCollection call after a committed collection), its `analytics` dependency, Runner construction, and Services.Analytics.
- Not a quest/progression system. Future quests would likely need per-player counters and further design; nothing about that is decided.

## Post-launch polish: rolling egg timer (deferred, 2026-10-29)
- Status: built but not wired for launch, by learner's choice ("polish, keep it here"). Eggs keep their authored Studio TextAttachment UI.
- Modules: src/ReplicatedStorage/Assets/UI/EggTimer.luau (React countdown: per-digit slide-down, 0.15 s, only changed digits move, leftover digit slides out and re-centres, fixed "s", stops at 0) and EggBillboard.luau (copies the authored TextAttachment UI into React, Timer -> EggTimer).
- To enable: require EggBillboard in Client.client.luau and uncomment the `decorate` hook passed to SpawningVisuals.new. SpawningVisuals' `decorate` dependency stays in place (optional, unused at launch).
- Not verified in Studio; reviewed by reading only.

## Target minigames (implemented 2026-10-29, direct implementation from learner's master spec)
- Configs/Targets/TargetConfig (timings, placement, temporary click, reward brackets [empty], Types -> ModelName); per-zone weights and run tuning in IdConfig Zones.<id>.Targets (egg lists moved to Zones.<id>.Eggs).
- Features/Targets: TargetRegistry (records/indexes), TargetPlacement (disk∩zone sampling, highest-priority zone, 3D clearance), TargetService (claims, runs, ack, ApplyHit seam for throwing, Sweep, settlement, cooldown), TargetSpawner (per-zone public schedule), TargetRewards (bracket boundary; no payout yet), RobloxTargetWorld (Workspace.Targets models + attributes).
- Features/Items/GroundProbe: ground step shared by eggs (PickupPlacement) and targets.
- Runner/Targets setup; Runner drives targets:Sweep every Heartbeat and targetSpawner:Step on the shared tick, both with workspace:GetServerTimeNow().
- Client: Shared/Features/Visuals/TargetVisuals (viewer modes, appear/leave, owner ack, temporary HUD); temporary click block in Client.client.luau.
- Blink: TargetStatus (server -> owner), TargetShown, HitTarget (client -> server).
- Asset: ReplicatedStorage.Assets.Targetables.Targets.Target is Studio-only; missing models disable their type with a warning.
