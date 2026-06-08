# Godot Multiplayer Project Comparison Matrix

This document compares four related Godot multiplayer projects:

- This project: `multi-server-test`.
- [Godot Tiny MMO](https://github.com/SlayHorizon/godot-tiny-mmo).
- [JDungeon](https://github.com/jonathaneeckhout/jdungeon).
- [Godot 4 Network Tutorial](https://github.com/somethinglikegames/godot4-network-tutorial).

The purpose is to keep the role-by-role comparison in one place. Detailed notes
live in:

- [Godot Tiny MMO Comparison Research](godot-tiny-mmo-comparison.md)
- [JDungeon Comparison Research](jdungeon-comparison.md)
- [Godot 4 Network Tutorial Comparison Research](godot4-network-tutorial-comparison.md)

## High-Level Matrix

| Area | This project | Godot Tiny MMO | JDungeon | Godot 4 Network Tutorial |
| --- | --- | --- | --- | --- |
| Primary goal | Minimal multi-server architecture spike | Experimental MMORPG framework | Open-source Godot MORPG game | Godot 4 networking tutorial |
| Godot version in inspected source | Godot 4.6 | Godot 4.6+ in README/source | Godot 4.2/.NET | Godot 4.1 |
| Project count | One Godot project | One Godot project | One Godot .NET project | Four separate Godot projects in one repo |
| Main entry | `shared/main/main.tscn` | `source/common/main.tscn` | `scenes/main/Main.tscn` | Each project uses `scenes/main.tscn` |
| Role selection | Feature tags for normal workflow; smoke/CI launches direct scenes. World scenes accept one bare world key. | `--mode` or feature tags | UI buttons in development; `--gateway` / `--server` in deployment | Separate project per role |
| Server roles | master_server, world_server | gateway, master, world | gateway, game server | authentication, gateway, world |
| Client role | Tiny playable client | MMO client with login/world/character/game UI | MORPG client with login/create-account/game UI | Login UI plus replicated 3D player client |
| Transport | Godot `WebSocketMultiplayerPeer` | Godot `WebSocketMultiplayerPeer` | Godot `WebSocketMultiplayerPeer` | Godot `ENetMultiplayerPeer` plus DTLS |
| Multiple multiplayer contexts | Yes: master, chat, world sibling branches | Yes: endpoint abstraction supports branch/root APIs | Yes: each connection node assigns its own branch `MultiplayerAPI` | Yes: branch-local `SceneMultiplayer` for gateway/auth/world branches |
| Chat | Separate `ChatNet` multiplayer branch hosted by master, persistent across world travel | World-local chat service with persistence/moderation | Game-server-local map chat | None |
| World travel | Client replaces active world peer between separate world processes | Instance/map switching inside world server architecture | Gateway-mediated server routing design; active checkout has portal logic commented | None; client manually chooses one world address |
| Replication | Godot high-level RPCs, `MultiplayerSpawner`, `MultiplayerSynchronizer` | Manual RPC spawn/despawn and custom byte-packed sync | Custom component sync with packed messages, prediction, interpolation | Godot `MultiplayerSpawner` and `MultiplayerSynchronizer` scene replication |
| Persistence | None | SQLite world/chat persistence; resource-backed master accounts | JSON dev backend, persistent player data, Postgres/BCrypt direction with a stale-loader caveat | None in inspected source; tutorial auth placeholder only |
| Auth | None | Gateway login/guest/account flow and world-entry tokens | Gateway login/account flow and game-server cookie handoff | Gateway/auth server login relay, HMAC peer auth, short-lived JWT world token |
| Deployment | Local CLI export and smoke scripts | Export intent plus role feature tags; local presets absent in inspected checkout | Export presets, Dockerfiles, docker-compose, GitHub Actions | Gateway export preset only; server projects use headless editor args |
| Automated verification | Log-based editor/export smoke tests | No formal test suite found in inspected checkout | GUT/format/build CI exists; one inspected unit test appears stale | No tests/CI found; crypto assets absent in inspected checkout |
| Best research value | Clean proof of separate contexts and world-peer replacement | Mature MMO architecture and custom sync direction | Gateway routing, component sync, prediction, Docker/CI deployment | Minimal auth token handoff and high-level spawner/synchronizer authority pattern |
| Main reason not to copy directly | Too small for production by design | Too broad and custom-sync-heavy for this MVP | Too game/framework/deployment-heavy for this MVP | Split across four projects and uses ENet/DTLS, not one WebSocket project |

## Role Purpose Matrix

| Role | This project | Godot Tiny MMO | JDungeon | Godot 4 Network Tutorial |
| --- | --- | --- | --- | --- |
| Client | Starts directly in a tiny playable scene. Connects to master for routes, chat for persistent chat, and one active world. Moves a `CharacterBody2D` and uses portals to switch world servers. | Starts at gateway/login UI. Handles login/guest flow, account and character workflows, world selection, realtime world connection, instance loading, and gameplay UI. | Starts with login/create-account UI. Connects to gateway, authenticates, gets game-server info, disconnects gateway, connects to game server, authenticates with cookie, loads map and player. | Starts at login UI. Connects to gateway, receives JWT, disconnects gateway, connects to manually entered world address, and runs replicated 3D player scene. |
| Master server | Minimal coordinator. Accepts world registrations, stores route data, exposes chat/world addresses, and answers route requests. | Central orchestrator. Bridges gateway requests, tracks worlds, coordinates accounts and character/world entry, issues world-entry auth tokens, receives heartbeats, and powers dashboard controls. | No separate master role. Routing/account responsibility is concentrated in the gateway and game-server registration flow. | No master role. There is no world registry; client enters the world address manually. |
| Gateway server | Not present. Clients talk directly to master because auth and public routing are out of scope. | Public/control-plane role. Handles HTTP login/account/world-entry requests and forwards them to master over Godot RPC. | Required role. Runs two WebSocket servers: one for game-server registration and one for client login/routing. Generates per-server cookies for clients. | Required role. Accepts client login over ENet/DTLS, forwards credentials to authentication server, returns JWT, then disconnects the client. |
| Authentication server | Not present. | Folded into master/gateway account flow. | Folded into gateway/database flow. | Separate ENet/DTLS server. Validates demo credentials, signs JWTs, and trusts gateway via HMAC peer auth. |
| Chat server | No standalone chat process. Master hosts chat on a separate WebSocket branch to prove chat survives active world peer replacement. | No standalone chat server in the inspected source. Chat lives in world server and integrates with channels, accounts, moderation, persistence, and dashboard logs. | No standalone chat server. Map chat lives on the game server through `ChatComponent` and `ChatServerRPC`; whisper is declared but not implemented in inspected source. | Not present. |
| World/game server | One shared world-server scene/script launched per key: `hub`, `left_world`, or `right_world`. Each process registers with master, accepts clients, spawns players, and hosts one visual world scene. | Main simulation host. Authenticates players using master-issued tokens, hosts instances/maps, manages player resources, chat, SQLite persistence, data requests, spawn/despawn, and custom sync. | Game server connects to gateway, registers one map/server name, hosts `BaseCamp`, accepts clients, validates cookies, spawns players, runs gameplay and component sync. | Performs post-connect JWT validation, spawns one level, spawns players, and demonstrates high-level scene replication. |
| Shared code | Small shared net config, endpoint scripts, world scenes, portal logic, and player scene/script. | Large shared layer for gameplay resources, maps, registries, network codecs, sync, utility code, content indexes, and role helpers. | Shared singleton/resource/component model. `J` registers scenes/resources; connection and sync components are reused across client/server roles. | Code is duplicated/copied between separate Godot projects where matching scene paths are needed. |
| Export/run tooling | Simple scripts export client, master_server, and one world_server artifact; smoke tests launch direct scenes and keyed world args. | Role routing supports feature tags and `--mode`; public docs discuss dedicated exports, but local `export_presets.cfg` was absent in inspected source. | Export presets for Linux dedicated server, Windows, and Web; Dockerfiles for gateway/server; docker-compose; GitHub Actions for builds/tests/images. | One gateway export preset found; server projects set editor headless run args; no full multi-role export/smoke loop found. |

## Server Orchestration Comparison

| Topic | This project | Godot Tiny MMO | JDungeon | Godot 4 Network Tutorial |
| --- | --- | --- | --- | --- |
| World registration | World servers register with master. | World servers register with master world-manager. | Game servers register with gateway. | None in inspected source. |
| Client route lookup | Client asks master for route snapshot. | Client asks gateway/master flow for available world/entry info. | Client asks gateway for a game server after login. | Client manually enters gateway and world address/port. |
| Transfer credential | None. World transfer is allowed by simple topology. | Master generates auth token and sends it to target world. | Gateway generates a UUID cookie and registers it on target game server. | Authentication server signs a short-lived JWT; world server validates it after client connection and disconnects failures. |
| Persistent control connection | Chat persists; master is temporary. | Gateway/control flow is separate from world socket. | Gateway is temporary for client; disconnected before game-server play. | Gateway is temporary for client; disconnected before world-server play. |
| Late server registration | No automatic client-side route refresh; clients use an initial live route snapshot from master. | Master world registry is central and heartbeat-aware. | Gateway stores registered game servers; current starter route hardcodes `BaseCamp`. | Not addressed. |
| Operational metadata | Route metadata includes endpoint and allowed-transfer data; heartbeat is bare and there is no health snapshot/dashboard. | Rich heartbeat snapshots and dashboard data. | Deployment config and server registration exist; no Tiny-MMO-style dashboard found. | None beyond connection logs and ENet RTT printing on client. |

## Synchronization Comparison

| Topic | This project | Godot Tiny MMO | JDungeon | Godot 4 Network Tutorial |
| --- | --- | --- | --- | --- |
| Spawn model | Godot `MultiplayerSpawner` under `SpawnRoot`. | Manual RPC spawn/despawn into instances. | Manual map/entity add/remove through sync components. | Godot `MultiplayerSpawner` for level and players. |
| Position sync | `MultiplayerSynchronizer` on player `position`; smoke does not deeply validate live movement. | Custom field-id state sync with `PathRegistry` and `WireCodec`; current player movement fields are client-owned. | Client input prediction, server reconciliation, timestamped interpolation/extrapolation. | Server-owned synchronizer watches `position` and `velocity`; input synchronizer sends `direction`. |
| Packet format | Godot RPC/high-level node replication. | Custom `PackedByteArray` deltas. | Batched `PackedByteArray` messages, using `Seriously.pack_to_bytes`. | Godot ENet high-level RPC and scene replication. |
| Interest management | None. | Entity grid AOI support; props still have future-AOI notes. | View/watch areas drive add/remove and position updates to interested players. | Tiny synchronizer visibility example using `set_visibility_for`. |
| Authority stance | Local player authority for movement plus server-side spawning/transfer checks. | Explicit client-owned vs server-owned sync fields; movement is not a server-authoritative reference in the inspected source. | Server-authority simulation with client input requests and server position correction. | Owning client has authority over input synchronizer; server owns resulting player state. |

## Godot Multiplayer Feature Usage

| Feature | This project | Godot Tiny MMO | JDungeon | Godot 4 Network Tutorial |
| --- | --- | --- | --- | --- |
| Uses `MultiplayerSpawner` at runtime | Yes. `shared/world/world.tscn` has a `MultiplayerSpawner` under the shared world scene, and `world.gd` spawns players through it. | No active runtime use found. Player and instance spawning are manual RPC/custom logic. A `MultiplayerSpawner` string appears in an editor plugin icon lookup only. | No active runtime use found in inspected main path. Entity creation/removal is manual through map/entity sync components. | Yes. World server uses `LevelSpawner` and level `PlayerSpawner`; client mirrors the required spawner structure. |
| Uses `MultiplayerSynchronizer` at runtime | Yes. `shared/player/player.tscn` synchronizes player `position`. | No active runtime use found. It uses custom state synchronizers, path registries, and packed deltas instead. | No active runtime use found in inspected main path. Its synchronizer-named components are custom scripts/RPC components, not Godot `MultiplayerSynchronizer` nodes. | Yes. Player scenes use `ServerSynchronizer` and `PlayerInput` `MultiplayerSynchronizer` nodes. |
| Uses Godot RPCs | Yes. Shared `master_endpoint.gd`, `chat_endpoint.gd`, and `world_endpoint.gd` expose high-level RPC endpoints. | Yes. RPCs are used for gateway/master/world control, data requests, manual spawn/despawn, and custom sync transport. | Yes. RPC components are central to client/gateway/server flow and custom component sync. | Yes. Login, auth forwarding, token response, world login, jump, and color switch use RPCs. |
| Primary replication style | Godot high-level nodes plus explicit RPC endpoints. | Custom RPC and byte-packed state deltas; no high-level spawner/synchronizer runtime dependency. | Custom component sync and batched RPC messages; no high-level spawner/synchronizer runtime dependency. | Godot high-level scene replication with spawners/synchronizers plus RPC login/auth. |

## What Each Project Is Best For

| Project | Best use as research | Do not use it for |
| --- | --- | --- |
| This project | Proving separate native multiplayer contexts, persistent chat, world-peer replacement, and exportable multi-process topology with minimal code. | Production auth, persistence, gameplay, prediction, or large-scale replication. |
| Godot Tiny MMO | Studying a Godot MMO framework architecture: gateway/master/world split, tokens, SQLite, custom sync, dashboards, richer gameplay systems. | A minimal high-level-node proof. It intentionally bypasses Godot spawner/synchronizer nodes for custom sync. |
| JDungeon | Studying a playable MORPG direction: gateway routing, WebSocket branch contexts, cookies, component sync, prediction/interpolation, Docker/CI. | A clean minimal world-transfer proof. The active checkout has portals commented and only `BaseCamp` registered. |
| Godot 4 Network Tutorial | Studying a small gateway/auth/world token handoff and Godot high-level scene replication with spawners/synchronizers. | A direct project layout or transport reference for this MVP. It uses four projects and ENet/DTLS, and the inspected checkout is missing crypto assets. |

## Recommended Borrowing Order

For the future MMO project, the lowest-risk borrowing order is:

1. Keep this project as the baseline topology test.
2. Borrow Godot 4 Network Tutorial's separated input/state synchronizer pattern.
3. Borrow JDungeon/Tiny MMO style config for ports and deployment mode.
4. Add a gateway/auth spike inspired by Tiny MMO, JDungeon, and Godot 4 Network Tutorial.
5. Add a route refresh and richer heartbeat/metadata model.
6. Add one tiny persistence spike, choosing SQLite or Postgres deliberately.
7. Add an instance/map resource model.
8. Only then compare high-level Godot synchronization against custom packet sync.

The big warning: do not mix every good idea into this MVP. The value of the
current project is that it isolates one networking question cleanly.
