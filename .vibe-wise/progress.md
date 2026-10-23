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

## Pending decision
Decision: Zone detection + spawn loop.
Stage: awaiting reasoning (Build checkpoint, follow-up).
Learner proposed: zones = tagged parts (CollectionService) with Priority attribute (0 lowest, highest wins); poll every ~0.2s using CFrame object-space check; while player is in a zone, roll random spawn timer from config; no spawning outside zones; item cap from a separate config; zone config holds loot table (AI reading of "loop table" — unconfirmed) + spawn times; loot tables differ per zone.
Resolved by learner: equal priority never allowed; loot tables are weighted; cap is per zone; zone shapes = Block + Cylinder; sampling ignores Y.
Also resolved: area formula dropped (learner concluded only extents needed); Y = item height + 3 or per-item config offset (baseline unclear); single interval loop over players; zone manager returns one zone or nil per player.
Learner proposed track algorithm: ZoneRegistry[player] -> zoneId|nil; SpawnTracks[player] -> track {zoneId, task}. If zoneId: if track and track.zoneId ~= zoneId -> cancel task (new track implied); elif track same zone -> return; elif no track -> create track. If zoneId nil -> do nothing.
Learner asked to start building (2026-10-22). AI suggested starting with ZoneManager (learner writes, AI reviews); spawn-track design deferred until then. Resolved: detection ignores Y (zones mostly hover above ground) — zones act as infinite vertical columns (AI noted). Blocking ZoneManager: cylinder detection now or blocks only. Open: spawn Y baseline given hovering zones (learner's message cut off at "Right now").
Awaiting: learner's trace of zone A -> no zone (track not cancelled when zoneId nil — AI flagged via trace prompt); return vs continue in player loop; old-zone items + cap count on zone change; SpawnTracks cleanup on PlayerRemoving; Y baseline (zone Y vs ground); whether detection ignores Y; confirm cap = per player per zone; behavior at cap.
