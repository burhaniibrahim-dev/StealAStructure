# Learning Progress

## Remote payloads / replication
- Introduced (AI explained): remotes send data; Instance refs only resolve if the client can see the Instance (ServerStorage -> nil).
- Demonstrated: learner applied it independently — send model name + Vector3, client looks up model in ReplicatedStorage.

## Server authority / pickup validation
- Demonstrated: learner proposed server-side registry of spawned items with server-issued IDs; client returns ID on pickup; server distance-checks against saved spawn position.
- Demonstrated (after prompt): per-player dictionary registry[player][id] gives ownership check; remove entry on pickup (replay); clear player's registry on leave.
- Initially trusted client-sent position (believed client couldn't know item position, though it's in the spawn payload). After AI re-explained, learner chose server-side HumanoidRootPart position — resolved.
- Introduced (AI explained): character position replicates to server; server-side position lags by ~ping, so range needs tolerance.
- Learner raised (unprompted): heartbeat speed check with rubberbanding for teleport exploits; accepted laggy-player tradeoff. Parked as separate later system; AI noted need to exempt intentional moves (respawn, teleports, knockback).

## Zone detection (spatial math)
- Demonstrated: learner recalled object-space approach (CFrame:ToObjectSpace) from prior work for point-in-zone checks.
- Introduced (AI explained): PointToObjectSpace + half-size comparison; handles rotated zones.
- Demonstrated: overlap resolution via Priority attribute (higher wins); CollectionService tags for zones; 0.2s polling rationale (not every Heartbeat).

- Demonstrated: priority tie rule — ties disallowed; new overlapping zone gets (max overlapping priority + 1); reasoned non-overlapping lower zones don't matter.
- Learner proposed: zones can be Blocks or Cylinders; ignore Y; sample X/Z (radius for cylinder) and place via object-space CFrame; intended area * 100 to avoid coarse integer randoms.
- Introduced (AI explained): Cylinder axis is X (circle in Y/Z object space); Random:NextNumber gives floats (no *100 needed); uniform-in-circle needs sqrt(u) radius or rejection sampling.

- Needs reinforcement: implemented root.CFrame:ToObjectSpace(zone.CFrame) (reversed reference frame). AI explained A:ToObjectSpace(B) = B relative to A; learner to fix.

- Learner asked for stress test of ZoneDetection (2026-10-22). AI found: nil foundZone index crash (kills WatchZones thread); "Priorirty" typo / missing attribute -> nil comparison crash; CharacterAdded:Wait/WaitForChild yield blocks loop for all players; ToObjectSpace still reversed; late zones lack Id; cylinder axes unhandled.
- Introduced (AI explained): uncaught error in task.spawn loop kills thread permanently; pcall-per-player vs make-every-step-safe tradeoff.
- Learner asked pcall vs task.spawn. AI explained: pcall = sync, catchable, yields still block; task.spawn = isolated thread, unobserved errors, overlapping ticks -> race/duplicate tracks. Expected states (no zone, missing priority) should be handled in logic, not error handling. Awaiting learner's choice.

## Module lifecycle / threads
- Needs reinforcement: ZoneSpawner returned task.spawn(Spawn) — ran at require time, returned one shared thread. AI explained modules run once and cache their return; return a function to start per-track threads.
- AI flagged SpawnTrackRegistry bugs: key mismatch (player vs player.UserId) -> Create every tick; field Task vs Track; `task` param shadows global.
- Awaiting: who starts/owns the spawn thread (ZoneService vs Create) and what args the spawn function needs.

## CollectionService
- Learner implemented ZoneService (GetTagged("ZONE"), GUID-based zone Id attribute, 0.3s loop) + ZoneDetection stub.
- Needs reinforcement: used CollectionService.TagAdded (fires with tag name string on first use) instead of GetInstanceAddedSignal; late-added zones get no Id. AI explained.
- Unknown "RigEdit" parent appearing in tagged set — AI suggested GetFullName diagnosis; likely a plugin (unverified); suggested unique tag / filtering (learner's choice).

## Direct implementation (2026-10-24)
Learner supplied a complete written spec for item spawning + floor pickup and explicitly asked for direct, working implementation (not a plan). Treated as an explicit direct-implementation request; learning loop bypassed for this feature only. Learning mode remains active.
The spec superseded several earlier learner choices: pickups are shared server-owned models (not per-client), ordinary spawning is per zone with population budgets (not one track per player), SpawnTrackRegistry kept only for personal tutorial sessions, client never sends pickup ids (touch/sweep on server). Learner-authored decisions kept: Priority attribute (highest wins, ties are errors), CollectionService tags, object-space checks, Block + Cylinder zones, ignore Y by default (now explicit "Column" mode; "Volume" optional).
Not demonstrated by learner: the implemented design's internals. Good candidates for a later System check: atomic collection without yields, generation-checked expiry, revisioned inventory updates.

## Pending decision (superseded 2026-10-24 by the direct implementation above)
Decision: Zone detection + spawn loop.
Stage: superseded; kept for history.
Learner proposed: zones = tagged parts (CollectionService) with Priority attribute (0 lowest, highest wins); poll every ~0.2s using CFrame object-space check; while player is in a zone, roll random spawn timer from config; no spawning outside zones; item cap from a separate config; zone config holds loot table (AI reading of "loop table" — unconfirmed) + spawn times; loot tables differ per zone.
Resolved by learner: equal priority never allowed; loot tables are weighted; cap is per zone; zone shapes = Block + Cylinder; sampling ignores Y.
Also resolved: area formula dropped (learner concluded only extents needed); Y = item height + 3 or per-item config offset (baseline unclear); single interval loop over players; zone manager returns one zone or nil per player.
Learner proposed track algorithm: ZoneRegistry[player] -> zoneId|nil; SpawnTracks[player] -> track {zoneId, task}. If zoneId: if track and track.zoneId ~= zoneId -> cancel task (new track implied); elif track same zone -> return; elif no track -> create track. If zoneId nil -> do nothing.
Learner asked to start building (2026-10-22). AI suggested starting with ZoneManager (learner writes, AI reviews); spawn-track design deferred until then. Resolved: detection ignores Y (zones mostly hover above ground) — zones act as infinite vertical columns (AI noted). Blocking ZoneManager: cylinder detection now or blocks only. Open: spawn Y baseline given hovering zones (learner's message cut off at "Right now").
Awaiting: learner's trace of zone A -> no zone (track not cancelled when zoneId nil — AI flagged via trace prompt); return vs continue in player loop; old-zone items + cap count on zone change; SpawnTracks cleanup on PlayerRemoving; Y baseline (zone Y vs ground); whether detection ignores Y; confirm cap = per player per zone; behavior at cap.

## Direct implementation: startup/feature-boundary refactor (2026-10-26)
Learner supplied a complete written design (agreed in an earlier brainstorming session) and asked for direct implementation and verification. Treated like the 2026-10-24 spec: learning loop bypassed for this refactor only; learning mode remains active.
Learner-decided: Runner keeps init order, shared registries, single inventory, Services publication, wiring, lifecycle, Heartbeat, debug, shutdown; setup children Runner.Data._Players, Runner.Zones (two-stage Init/StartSpawner), Runner.Eggs; no Inventory setup module; Items -> EggService/EggRegistry under Features/Items/Eggs with Items/Tools reserved; Services.Items -> Services.Eggs; pickup analytics disconnected for MVP but retained.
AI-chosen details (not learner decisions): Runner/ directory with init.server.luau for the Rojo hierarchy; getRootPosition/isPlayerPresent split into Util/RobloxPlayers; placement/exclusions/world adapters classified as egg-specific; shared Random created in Runner; ZoneSpawner dep renamed to eggRegistry.
Not demonstrated by learner: none of the above was implemented by the learner. Candidate System check: why the spawner must be built after eggs, and why the registry is shared rather than owned by EggService.

## Pending decision: client-side owner-only eggs redesign (2026-10-27)
Stage (2026-10-28): settled parts implemented (records, collection authority, owner-only Blink, client visuals/proximity, split configs, validator, tests 76/76). 2026-10-29: learner approved the timing shape, chose r = 0.9 ("very close to 1" so zones look fuller), and required every timing number to live in SpawnerConfig (SpawnIntervalCurve, FirstSpawnDelay, ReentryCreditMultiplier). Implemented; tests 86/86. Tutorial PAUSED by learner until every other system is done (it depends on all of them); Eggs_Tutorial untouched, Tutorial.spec held out, collection gate still reads the saved flag (default true).
Learner decided (answers A–G): Base = soft per-player/zone target, MaxPickups = hard per-player/zone cap, MaxPickupsPerPlayer = hard total; first egg ~0.5s; count-driven interval; pause at caps, no backlog; re-entry credit per zone for 5× max interval; death resets schedules; client proximity → PickupId request, 20 req/tick rate limit, no auto-retry while in range; templates must exist at startup (fail loudly), runtime-missing → common-egg visual fallback + warn; remaining lifetime sent, client waits for EggRemoved; HUD re-enabled; per-owner debug log; reset button disabled.
AI-chosen details: VisualFallback flag on catalog entry (SnowEgg); PickupRadius repurposed as client trigger radius sent in EggSnapshot; CollectRequestsPerTick in PickupConfig; Tutorial.spec held out of run until D.
Learner's GDD (claude.ai artifact 7PXzV4JCChE5KyoQv7TtYq) is a design source: tutorial holds back spawns until the Collect step; scripted egg worth more.
Learner spec (direct implementation requested, question gate mandatory): server owns data-only records with OwnerUserId; each client clones Assets.Eggs.PickUps templates locally; owner-only Blink spawn/remove/snapshot; collection request = PickupId only; no fallback models ("MODEL OF {NAME} doesnt exist", disable type); split configs injected by Runner; no population multipliers.
Open (asked): BasePickups/MaxPickups meaning + initial fill; zone change and death behavior; collection trigger; tutorial/scripted classification + Eggs_Tutorial boundary; model check timing + recovery; expiry transmission; HUD re-enable; debug log consumer.
