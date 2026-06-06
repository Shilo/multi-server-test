# Godot Multiplayer Project Comparison Matrix

This document compares three related Godot multiplayer projects:

- This project: `multi-server-test`.
- [Godot Tiny MMO](https://github.com/SlayHorizon/godot-tiny-mmo).
- [JDungeon](https://github.com/jonathaneeckhout/jdungeon).

The purpose is to keep the role-by-role comparison in one place. Detailed notes
live in:

- [Godot Tiny MMO Comparison Research](godot-tiny-mmo-comparison.md)
- [JDungeon Comparison Research](jdungeon-comparison.md)

## High-Level Matrix

| Area | This project | Godot Tiny MMO | JDungeon |
| --- | --- | --- | --- |
| Primary goal | Minimal multi-server architecture spike | Experimental MMORPG framework | Open-source Godot MORPG game |
| Godot version in inspected source | Godot 4.6 | Godot 4.6+ in README/source | Godot 4.2/.NET |
| Project count | One Godot project | One Godot project | One Godot .NET project |
| Main entry | `launcher/Launcher.tscn` | `source/common/main.tscn` | `scenes/main/Main.tscn` |
| Role selection | CLI `--role`, plus `--world` | `--mode` or feature tags | UI buttons in development; `--gateway` / `--server` in deployment |
| Server roles | master, chat, world 1, world 2, world 3 | gateway, master, world | gateway, game server |
| Client role | Tiny playable client | MMO client with login/world/character/game UI | MORPG client with login/create-account/game UI |
| Transport | Godot `WebSocketMultiplayerPeer` | Godot `WebSocketMultiplayerPeer` | Godot `WebSocketMultiplayerPeer` |
| Multiple multiplayer contexts | Yes: master, chat, world sibling branches | Yes: endpoint abstraction supports branch/root APIs | Yes: each connection node assigns its own branch `MultiplayerAPI` |
| Chat | Separate chat server, persistent across world travel | World-local chat service with persistence/moderation | Game-server-local map chat |
| World travel | Client replaces active world peer between separate world processes | Instance/map switching inside world server architecture | Gateway-mediated server routing design; active checkout has portal logic commented |
| Replication | Godot high-level RPCs, `MultiplayerSpawner`, `MultiplayerSynchronizer` | Manual RPC spawn/despawn and custom byte-packed sync | Custom component sync with packed messages, prediction, interpolation |
| Persistence | None | SQLite world/chat persistence; resource-backed master accounts | JSON dev backend, persistent player data, Postgres/BCrypt direction with a stale-loader caveat |
| Auth | None | Gateway login/guest/account flow and world-entry tokens | Gateway login/account flow and game-server cookie handoff |
| Deployment | Local CLI export and smoke scripts | Export intent plus role feature tags; local presets absent in inspected checkout | Export presets, Dockerfiles, docker-compose, GitHub Actions |
| Automated verification | Log-based editor/export smoke tests | No formal test suite found in inspected checkout | GUT/format/build CI exists; one inspected unit test appears stale |
| Best research value | Clean proof of separate contexts and world-peer replacement | Mature MMO architecture and custom sync direction | Gateway routing, component sync, prediction, Docker/CI deployment |
| Main reason not to copy directly | Too small for production by design | Too broad and custom-sync-heavy for this MVP | Too game/framework/deployment-heavy for this MVP |

## Role Purpose Matrix

| Role | This project | Godot Tiny MMO | JDungeon |
| --- | --- | --- | --- |
| Client | Starts directly in a tiny playable scene. Connects to master for routes, chat for persistent chat, and one active world. Moves a `CharacterBody2D` and uses portals to switch world servers. | Starts at gateway/login UI. Handles login/guest flow, account and character workflows, world selection, realtime world connection, instance loading, and gameplay UI. | Starts with login/create-account UI. Connects to gateway, authenticates, gets game-server info, disconnects gateway, connects to game server, authenticates with cookie, loads map and player. |
| Master server | Minimal coordinator. Accepts world registrations, stores route data, exposes chat/world addresses, and answers route requests. | Central orchestrator. Bridges gateway requests, tracks worlds, coordinates accounts and character/world entry, issues world-entry auth tokens, receives heartbeats, and powers dashboard controls. | No separate master role. Routing/account responsibility is concentrated in the gateway and game-server registration flow. |
| Gateway server | Not present. Clients talk directly to master because auth and public routing are out of scope. | Public/control-plane role. Handles HTTP login/account/world-entry requests and forwards them to master over Godot RPC. | Required role. Runs two WebSocket servers: one for game-server registration and one for client login/routing. Generates per-server cookies for clients. |
| Chat server | Separate WebSocket server dedicated to chat echo and sender-id display. It exists to prove chat survives active world peer replacement. | No standalone chat server in the inspected source. Chat lives in world server and integrates with channels, accounts, moderation, persistence, and dashboard logs. | No standalone chat server. Map chat lives on the game server through `ChatComponent` and `ChatServerRPC`; whisper is declared but not implemented in inspected source. |
| World/game server | One shared world-server scene/script launched three times. Each process registers with master, accepts clients, spawns players, authorizes simple portal targets, and hosts one visual world scene. | Main simulation host. Authenticates players using master-issued tokens, hosts instances/maps, manages player resources, chat, SQLite persistence, data requests, spawn/despawn, and custom sync. | Game server connects to gateway, registers one map/server name, hosts `BaseCamp`, accepts clients, validates cookies, spawns players, runs gameplay and component sync. |
| Shared code | Small shared config, CLI parsing, endpoint scripts, and constants. | Large shared layer for gameplay resources, maps, registries, network codecs, sync, utility code, content indexes, and role helpers. | Shared singleton/resource/component model. `J` registers scenes/resources; connection and sync components are reused across client/server roles. |
| Export/run tooling | Simple scripts export one shared artifact into role-labeled folders and run log-based smoke tests for editor/headless and exported artifacts. | Role routing supports feature tags and `--mode`; public docs discuss dedicated exports, but local `export_presets.cfg` was absent in inspected source. | Export presets for Linux dedicated server, Windows, and Web; Dockerfiles for gateway/server; docker-compose; GitHub Actions for builds/tests/images. |

## Server Orchestration Comparison

| Topic | This project | Godot Tiny MMO | JDungeon |
| --- | --- | --- | --- |
| World registration | World servers register with master. | World servers register with master world-manager. | Game servers register with gateway. |
| Client route lookup | Client asks master for route snapshot. | Client asks gateway/master flow for available world/entry info. | Client asks gateway for a game server after login. |
| Transfer credential | None. World transfer is allowed by simple topology. | Master generates auth token and sends it to target world. | Gateway generates a UUID cookie and registers it on target game server. |
| Persistent control connection | Chat persists; master is temporary. | Gateway/control flow is separate from world socket. | Gateway is temporary for client; disconnected before game-server play. |
| Late server registration | Current project has limited route refresh. | Master world registry is central and heartbeat-aware. | Gateway stores registered game servers; current starter route hardcodes `BaseCamp`. |
| Operational metadata | Bare heartbeat only. | Rich heartbeat snapshots and dashboard data. | Deployment config and server registration exist; no Tiny-MMO-style dashboard found. |

## Synchronization Comparison

| Topic | This project | Godot Tiny MMO | JDungeon |
| --- | --- | --- | --- |
| Spawn model | Godot `MultiplayerSpawner` under `SpawnRoot`. | Manual RPC spawn/despawn into instances. | Manual map/entity add/remove through sync components. |
| Position sync | `MultiplayerSynchronizer` on player `position`; smoke does not deeply validate live movement. | Custom field-id state sync with `PathRegistry` and `WireCodec`; current player movement fields are client-owned. | Client input prediction, server reconciliation, timestamped interpolation/extrapolation. |
| Packet format | Godot RPC/high-level node replication. | Custom `PackedByteArray` deltas. | Batched `PackedByteArray` messages, using `Seriously.pack_to_bytes`. |
| Interest management | None. | Entity grid AOI support; props still have future-AOI notes. | View/watch areas drive add/remove and position updates to interested players. |
| Authority stance | Local player authority for movement plus server-side spawning/transfer checks. | Explicit client-owned vs server-owned sync fields; movement is not a server-authoritative reference in the inspected source. | Server-authority simulation with client input requests and server position correction. |

## What Each Project Is Best For

| Project | Best use as research | Do not use it for |
| --- | --- | --- |
| This project | Proving separate native multiplayer contexts, persistent chat, world-peer replacement, and exportable multi-process topology with minimal code. | Production auth, persistence, gameplay, prediction, or large-scale replication. |
| Godot Tiny MMO | Studying a Godot MMO framework architecture: gateway/master/world split, tokens, SQLite, custom sync, dashboards, richer gameplay systems. | A minimal high-level-node proof. It intentionally bypasses Godot spawner/synchronizer nodes for custom sync. |
| JDungeon | Studying a playable MORPG direction: gateway routing, WebSocket branch contexts, cookies, component sync, prediction/interpolation, Docker/CI. | A clean minimal world-transfer proof. The active checkout has portals commented and only `BaseCamp` registered. |

## Recommended Borrowing Order

For the future MMO project, the lowest-risk borrowing order is:

1. Keep this project as the baseline topology test.
2. Borrow JDungeon/Tiny MMO style config for ports and deployment mode.
3. Add a gateway/auth spike inspired by both Tiny MMO and JDungeon.
4. Add a route refresh and richer heartbeat/metadata model.
5. Add one tiny persistence spike, choosing SQLite or Postgres deliberately.
6. Add an instance/map resource model.
7. Only then compare high-level Godot synchronization against custom packet sync.

The big warning: do not mix every good idea into this MVP. The value of the
current project is that it isolates one networking question cleanly.
