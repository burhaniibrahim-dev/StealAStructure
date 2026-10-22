# Project Map

## Purpose
Roblox game. Current feature: detect which zone each player is in and spawn configured items in those zones as client-side models.

## Requirements
- Zones are box-shaped (square/rectangular) parts; zone size comes from the part.
- Learner wants zone detection on the server (stated as "probably", not yet decided).
- On an interval, the server tells clients what to spawn; item models are spawned client-side.
- Which items spawn in which zone comes from config files.
- Items are per-client: each player sees/owns their own spawned items.
- Items are collectible; collected items go to the player's inventory (inventory system is later work) and can be thrown.
- Chosen (learner): server decides spawn position + model name; remote payload = model name + Vector3; client clones model from ReplicatedStorage by name.

## Components
Verified existing:
- Networking: Blink (generated) — schema `Remotes.blink`; outputs `src/ServerScriptService/Networker/Server.luau` and `src/ReplicatedStorage/Shared/Networker/Client.luau`. No events defined yet.
- Client entry: `src/StarterPlayer/StarterPlayerScripts/Client.client.luau` (requires Networker client only).
- Packages (Wally): Janitor, React, ReactRoblox, Promise.
Chosen (confirmed, not implemented) — Item registry & pickup:
- Server sends `{ id, name, position }` to the owning player only.
- Client clones `name` from ReplicatedStorage and places it at `position`.
- Server registry: `registry[player][id] = { name, position }`; IDs randomly generated.
- Pickup: client sends `id` only; server checks id is in that player's registry and server-side HumanoidRootPart is within collection range of saved position; on success removes entry and grants item (inventory = later work).
- PlayerRemoving clears that player's registry.
- AI addition (approved): server collection range = client pickup range + buffer, both in config.
- Unresolved: client-side removal timing (optimistic vs wait for server confirm).
In progress (learner-written): `src/ServerScriptService/Features/Zones/ZoneService.luau` (tag collection, zone Ids, 0.3s CheckPlayers loop + track logic), `ZoneDetection.luau` (stub), `SpawnTrackRegistry` (required; not reviewed).
Zone detection decided: ignore Y (zones are infinite vertical columns); priority attribute, ties disallowed.
Not yet designed: zone/item config shape.
Later work: inventory; speed/teleport anti-cheat (separate system).

## Main Flow
Server: player position -> ? zone check -> which zone   [not yet designed]
Server (interval, ?) --{id, name, position}--> owning Client   [payload chosen]
Client: clone ReplicatedStorage model by name -> place at position   [chosen]
Client --{id}--> Server: registry lookup + HRP distance check -> remove entry, grant item   [chosen]

## Data and Trust Boundaries
Unknown. Open question: what the server sends vs. what the client decides.

## Build and Deployment
Rojo project: `default.project.json`. Toolchain: `rokit.toml`, `wally.toml`, selene, stylua.

## Unknowns
- Zone check method, interval, payload shape, where configs live, how spawned items are collected/validated.
