# Godot Tiny MMO Comparison Research

This note compares this project, `multi-server-test`, against
[SlayHorizon/godot-tiny-mmo](https://github.com/SlayHorizon/godot-tiny-mmo).

The goal is not to copy Godot Tiny MMO into this spike. The goal is to learn
from a more mature Godot MMO experiment, identify which ideas strengthen this
project, and keep a clear line between this MVP and future MMO framework work.

## Executive Summary

Godot Tiny MMO is a much more mature experimental MMORPG framework. It has a
gateway server, master server, world server, login flow, account and character
systems, SQLite-backed world persistence, chat, dashboard tooling, manual
instance management, and a custom byte-packed synchronization layer.

This project is intentionally smaller. It proves one shared Godot project with
one client, one master server, one separate chat server, three world servers,
WebSocket-based Godot high-level multiplayer, separate client multiplayer
contexts, high-level RPCs, branch-local portal travel, and server-authority
spawning through `MultiplayerSpawner`. It also includes a
`MultiplayerSynchronizer` for player `position`, but live movement
synchronization is still best validated manually with two visible clients rather
than by the current smoke test.

The strongest takeaway is that this spike should stay small. Godot Tiny MMO
shows many ideas worth borrowing later, especially role routing, endpoint
wrappers, config files, world registration, heartbeats, token-based world entry,
instance resources, and explicit sync authority boundaries. It also shows what
not to pull into this MVP yet: authentication, SQLite, custom packet codecs,
admin dashboards, gameplay systems, and production orchestration.

## Source Material Reviewed

Local source reviewed:

- This project: `C:\Programming_Files\Shilocity\Godot\Tests\multi-server-test`
- Godot Tiny MMO: `C:\Programming_Files\Godot\godot-tiny-mmo`
- Godot Tiny MMO local main commit observed during research: `e4b40f8`

Public Godot Tiny MMO sources reviewed:

- [Repository](https://github.com/SlayHorizon/godot-tiny-mmo)
- [Documentation site](https://slayhorizon.github.io/godot-tiny-mmo/)
- [gh-pages documentation branch](https://github.com/SlayHorizon/godot-tiny-mmo/tree/gh-pages)
- [Overview](https://slayhorizon.github.io/godot-tiny-mmo/#/pages/overview?id=introduction)
- [Run Project](https://slayhorizon.github.io/godot-tiny-mmo/#/pages/run_project)
- [Export](https://slayhorizon.github.io/godot-tiny-mmo/#/pages/export)
- [Next Level Notes](https://slayhorizon.github.io/godot-tiny-mmo/#/pages/notes/next_level)
- [Customize Run Instances](https://slayhorizon.github.io/godot-tiny-mmo/#/pages/godot_tips/customize_run_instances)
- [Archived Synchronization Notes](https://slayhorizon.github.io/godot-tiny-mmo/#/pages/archives/synchronization)

Subagent review was used for two focused sweeps:

- One subagent mapped the local Godot Tiny MMO source structure and key scripts.
- One subagent compared the public docs and `gh-pages` branch against the local
  source tree and found several documentation freshness gaps.

## Documentation Freshness Warning

Godot Tiny MMO's public docs are useful but behind the current local source.
The docs still describe older paths like `gateway_server`, `master_server`, and
`world_server`, while current source uses paths under `source/server/gateway`,
`source/server/master`, and `source/server/world`.

The public docs also mention Godot 4.4 in places, while the current README says
Godot 4.6+. The docs discuss older string and dictionary synchronization
patterns, while current source contains `StateSynchronizer`, `PathRegistry`, and
`WireCodec` based byte packing.

For Godot Tiny MMO, current local source and README should be treated as the
stronger source of truth. The public docs are still valuable for conceptual
history, run-instance guidance, and export intent.

## High-Level Comparison

| Area | This project | Godot Tiny MMO |
| --- | --- | --- |
| Goal | Minimal multi-server proof-of-concept | Experimental MMORPG framework |
| Godot project count | One | One |
| Entry point | `launcher/Launcher.tscn` selects `--role` | `source/common/main.tscn` selects `--mode` or feature tags |
| Client | One simple playable client | Login UI, gateway flow, character/world selection, gameplay UI |
| Master | Minimal route and world registry server | Gateway bridge, account orchestration, world registry, dashboard control |
| Chat | Separate chat server process | Chat service inside world server |
| Worlds | Three explicit world server processes | World server with instance manager and multiple map resources |
| Travel | Client disconnects active world peer and connects to another world server | Client switches instances/maps inside world infrastructure through a server-driven transition, optionally gated by instance rules |
| Networking | Godot WebSocket high-level multiplayer, RPCs, branch-local `MultiplayerAPI` | Godot WebSocket high-level multiplayer plus custom RPC request and byte-packed sync |
| Replication | `MultiplayerSpawner` plus optional `MultiplayerSynchronizer` for `position` | Manual spawn/despawn RPC and custom `PackedByteArray` state deltas |
| Persistence | None | SQLite for world data and chat, resource-backed accounts on master |
| Auth | None | Gateway login, guest login, world-entry auth tokens |
| Export | Simple shared artifact copied to role folders | Export intent documented, no local `export_presets.cfg` found |
| Automated tests | Log-driven smoke test scripts | No formal test suite found during research |
| Scope | Small, explicit, disposable | Broad, framework-like, gameplay-heavy |

## This Project's Architecture

This project is a narrow validation spike. It proves the following shape:

- A single Godot project.
- One role-selecting launcher scene.
- Separate role folders for client, master, chat, world, shared code, and tools.
- A master route server.
- A separate chat server.
- Three separate world server processes.
- One client with independent networking branches.
- Portal travel that replaces only the active world connection.
- Chat that stays connected while world connections change.

The important scene branches on the client are:

- `MasterNet/MasterEndpoint`
- `ChatNet/ChatEndpoint`
- `WorldNet/WorldEndpoint`

Each branch receives its own `MultiplayerAPI` with `SceneTree.set_multiplayer`.
This is the critical Godot-native validation: one client can keep separate
native multiplayer contexts alive at the same time as long as the branches are
sibling branches and RPC paths match below each branch.

World server scenes mirror the world branch path used by the client:

- `WorldNet/WorldEndpoint`
- `WorldNet/WorldSceneRoot`
- `WorldNet/WorldSceneRoot/World1`, `World2`, or `World3`
- `WorldNet/WorldSceneRoot/.../SpawnRoot`

That matching path is what lets high-level RPC, `MultiplayerSpawner`, and
`MultiplayerSynchronizer` work without a custom replication framework.

## Godot Tiny MMO Architecture

Godot Tiny MMO also uses one Godot project, but it aims at a larger MMORPG
framework. Its main scene is `source/common/main.tscn`, and role routing lives
in `source/common/main.gd`.

Role selection checks command-line `--mode` first, then Godot feature tags:

- `client`
- `gateway-server`
- `master-server`
- `world-server`

The main source layout is:

- `addons/`: bundled `godot-sqlite`, HTTP server, and Tiny MMO editor plugin.
- `assets/`: art, audio, fonts, and UI assets.
- `data/config/`: client, gateway, master, world, dashboard, admin, and TLS config.
- `source/client/`: login UI, gateway flow, client autoload, instance client, UI.
- `source/common/`: shared gameplay, maps, registries, network codec, sync, utilities.
- `source/server/gateway/`: HTTP gateway and RPC client to master.
- `source/server/master/`: account orchestration, world registry, gateway bridge, dashboard.
- `source/server/world/`: world server, instance hosting, SQLite persistence, chat, moderation, data request handlers.

The most important server split is:

- Gateway server: HTTP-facing login, account, guest, character, and world-entry endpoints.
- Master server: receives gateway requests, manages accounts, tracks worlds, issues world-entry tokens, exposes dashboard control.
- World server: accepts authenticated realtime players, hosts instances, manages chat, persistence, sync, and gameplay requests.

## Networking And Endpoint Setup

Godot Tiny MMO wraps Godot networking in
`source/common/network/endpoints/base_multiplayer_endpoint.gd`.

That wrapper creates:

- `WebSocketMultiplayerPeer`
- `SceneMultiplayer`
- server or client peer
- optional root or branch-local multiplayer assignment
- `server_relay = false`

This is one of the most directly useful patterns for future work. This project
currently keeps endpoints explicit and small because the MVP only has a few
branches. A tiny endpoint wrapper could be useful after this spike, but adding a
general endpoint framework too early would make the MVP harder to read.

Godot Tiny MMO uses multiple process-local networking relationships:

- Gateway connects to master over a manager socket.
- World connects to master over a manager socket.
- World accepts player clients over a separate realtime socket.
- Client uses gateway HTTP first, then connects to the chosen world socket.

One source comment in Godot Tiny MMO's world manager is especially relevant to
this project: the world process has one multiplayer context for the master
connection and another multiplayer context for player connections, so code must
use the correct peer table. That mirrors this spike's core lesson: chat, master,
and world responsibilities should not be treated as one global multiplayer peer.

## Master, Gateway, And World Registration

This project's master server is deliberately tiny:

- It accepts world registrations.
- It records world IDs, WebSocket URLs, scene paths, and allowed target worlds.
- It returns initial routes to clients.

Godot Tiny MMO's master role is broader:

- It accepts gateway-manager connections.
- It accepts world-manager connections.
- It stores connected world snapshots.
- It handles login, account creation, character creation, character listing, and world entry requests.
- It generates temporary auth tokens and sends them to worlds before clients connect.
- It exposes dashboard status and administrative commands.

For this project, the registration idea is worth keeping. The authentication and
dashboard parts are valuable future references, but they are out of scope for
the current test.

## Authentication And World Entry

Godot Tiny MMO's world-entry flow is a useful production-shaped pattern:

1. Client logs in or creates a guest account through the gateway HTTP API.
2. Gateway forwards the request to master over Godot RPC.
3. Master validates the account and character.
4. Client asks to enter a world.
5. Master generates a temporary auth token.
6. Master sends the token to the target world server.
7. Gateway returns the target world address, port, and auth token to the client.
8. Client connects to the world server and sends the auth token during peer authentication.
9. World validates and consumes the token.

That pattern is worth documenting for future work. It keeps the public login
surface away from the realtime world socket and lets the master coordinate
world entry without making the world trust arbitrary clients.

It should not be added to this MVP. This spike does not need accounts, login,
security, character selection, or token persistence to prove the native
multiplayer topology.

Security note: the inspected Godot Tiny MMO source appears to store master
account passwords as plain resource strings, and token generation is demo-grade.
That is fine for a demo, but it should not be copied into a real MMO without
proper password hashing, cryptographic token generation, expiry, and session
validation.

## SQLite And Persistence

Godot Tiny MMO bundles `addons/godot-sqlite` and uses SQLite on the world server.

The world database layer includes:

- Schema migrations.
- Account rows mirrored into world storage.
- Player rows.
- Guilds.
- Guild members.
- Flags.
- Conversations.
- Messages.
- Periodic saves.
- Database backups.

Chat persistence is also SQLite-backed through a chat store.

This is valuable future research, especially because SQLite is a practical
first persistence layer for a local Godot MMO prototype. It should remain out of
scope for this project. The current test needs repeatable process startup,
connection, chat echo, world transfer, and spawn behavior, not persistent
characters.

Recommended future spike:

- Keep this project's topology.
- Add one minimal persistent character record.
- Use a small SQLite table only for player name and last world.
- Avoid importing the full Godot Tiny MMO schema until the persistence goal is clearer.

## Chat Comparison

This project intentionally runs chat as a separate server process. That is a
clean fit for the original goal: prove chat can stay connected while world
connections are replaced.

Godot Tiny MMO currently runs chat inside the world server. That makes sense for
its framework because chat is integrated with accounts, blocks, moderation,
world channels, guild/team channels, database persistence, and dashboard logs.

Both approaches are valid for different goals.

This project's separate chat server is better for proving independent
multiplayer contexts.

Godot Tiny MMO's world-local chat service is better for a gameplay framework
where chat needs player resources, account data, moderation tools, and
persistence.

For this spike, keep the separate chat server. For a future MMO, consider a
hybrid:

- Keep a separate chat connection if persistent cross-world chat is a hard requirement.
- Let world servers publish player presence and instance channel membership to chat.
- Add persistence only after the message model is stable.

## Travel And Instance Switching

This project demonstrates server travel between separate world server processes:

1. Local player enters a portal.
2. Client asks the active world server for transfer approval.
3. Active world validates the target world against its allowed topology.
4. Client disconnects from the current world peer.
5. Client replaces only `WorldNet`'s multiplayer peer.
6. Client connects to the target world server.
7. Target world spawns the player under `SpawnRoot`.
8. Chat remains connected through `ChatNet`.

Godot Tiny MMO primarily demonstrates instance and map switching within a world
server architecture:

1. Server detects a warper or instance switch.
2. Server despawns the player from the old instance.
3. Client receives a `charge_new_instance` RPC with the target map and instance ID.
4. Client loads the new map.
5. Client signals ready.
6. Server spawns the player in the target instance.

This is a different travel problem. Godot Tiny MMO is closer to zone or instance
travel inside a world server. This project is closer to shard or world-server
travel, because the active Godot peer is replaced.

The idea worth borrowing is the explicit transition handshake:

- server drives the target decision
- optional instance rules can gate entry
- client unloads old view
- client loads target view
- client signals ready
- server spawns or confirms spawn

In current Godot Tiny MMO source, `InstanceResource.can_join_instance` is the
extension point for entry rules, and the default allows joins. The server still
owns the transition, with special-case blocking such as jail routing.

This project already has a smaller version of that handshake. Future work could
make it more explicit before adding persistence or auth.

## Synchronization Comparison

This project uses Godot high-level multiplayer nodes:

- `MultiplayerSpawner` spawns players under `SpawnRoot`.
- `MultiplayerSynchronizer` can synchronize `position`.
- RPCs handle route, chat, world state, and transfer messages.

Godot Tiny MMO explicitly does not rely on `MultiplayerSpawner` or
`MultiplayerSynchronizer` for gameplay synchronization. It uses:

- manual spawn/despawn RPCs
- `StateSynchronizer`
- `StateSynchronizerManagerServer`
- `StateSynchronizerManagerClient`
- `PathRegistry`
- `WireCodec`
- `PackedByteArray` deltas
- `ReplicatedPropsContainer`
- entity grid AOI support, while replicated props still have comments noting
  that AOI is future work

That custom stack is extremely relevant research for a future MMO. It provides
more control over bandwidth, ownership, field IDs, baseline/delta encoding, and
server authority. It is also a major increase in complexity.

For this project, custom byte-level synchronization is out of scope. The stated
goal is to prove Godot native high-level multiplayer with RPCs,
`MultiplayerSpawner`, and `MultiplayerSynchronizer`. Godot Tiny MMO's sync layer
should be documented as a future alternative, not implemented here.

The immediately useful lesson is not the byte codec itself. The useful lesson is
the authority model:

- Decide which fields are client-owned.
- Decide which fields are server-owned.
- Avoid synchronizing transfer-critical state in a way that makes one player's
  world transition look like every player's transition.
- Tear down or isolate replicated world state when a client changes world peers.

## Run Instances And CLI Strategy

Both projects support one-project multi-role testing from the editor.

Godot Tiny MMO's docs emphasize Debug > Customize Run Instances and feature
tags:

- one `gateway-server`
- one `master-server`
- one `world-server`
- one or more `client`

The current source also supports `--mode=client`, `--mode=gateway-server`,
`--mode=master-server`, and `--mode=world-server`.

This project uses command-line role arguments:

- `--role client`
- `--role master`
- `--role chat`
- `--role world --world 1`
- `--role world --world 2`
- `--role world --world 3`

This project's approach is more explicit for the spike, especially because the
world role needs a world ID. Godot Tiny MMO's feature-tag approach is useful for
editor convenience and export presets. A future small improvement would be to
support both forms:

- keep `--role` and `--world` for scripts and smoke tests
- optionally accept feature tags or `--mode` for editor ergonomics

Do not change the MVP unless run-instance setup becomes painful.

## Export Strategy

This project has a working simple export story:

- one shared exported Windows build
- copied into role-labeled folders
- role behavior selected by CLI arguments
- automated smoke test can run exported artifacts

Godot Tiny MMO's docs describe separate client and dedicated-server exports and
feature-tagged export behavior. The current local source has an export plugin
that keeps autoloads registered and lets scripts self-free depending on role.
However, no local `export_presets.cfg` was found during this research pass.

For this spike, the current export strategy is correct. It proves the shared
project can produce independently launched role artifacts without multiplying
Godot projects. More precise role-specific export presets would be useful later
when assets, server-only scripts, or platform differences become expensive.

## Current Project Pros

- Extremely easy to understand.
- One Godot project.
- Clear role folders.
- Separate chat server process.
- Separate world server processes.
- Explicit world topology.
- Demonstrates multiple branch-local `MultiplayerAPI` contexts.
- Uses Godot high-level multiplayer APIs directly.
- Uses `MultiplayerSpawner` and `MultiplayerSynchronizer` instead of custom sync.
- Has log-driven smoke tests.
- Has exported-artifact smoke tests.
- Uses minimal `res://icon.svg` visuals.
- Easy to throw away or evolve.

## Current Project Cons

- No authentication or account model.
- No persistent characters.
- No route refresh if worlds register after the client's first route snapshot.
- Has only a bare world heartbeat, with no heartbeat snapshot, population,
  liveness timeout, or rich metadata.
- No gateway role.
- No admin/dashboard visibility.
- No real instance manager or map resource system.
- No interest management.
- No production transfer tickets.
- No robust retry orchestration for manual editor startup races.
- Synchronization is intentionally minimal and will need more authority testing.

These are not failures for the MVP. They are mostly future-work boundaries.

## Godot Tiny MMO Pros

- More complete MMO-shaped architecture.
- Clear gateway/master/world role split.
- HTTP gateway separates login/control requests from realtime world sockets.
- Master tracks worlds and coordinates world entry.
- Temporary world-entry token flow is a useful pattern.
- SQLite world persistence is already explored.
- Chat includes persistence and moderation concepts.
- Manual instance manager supports map switching and instance lifecycle.
- Custom synchronization layer documents a path beyond Godot's stock nodes.
- Config files make local topology easier to change.
- Dashboard and heartbeat snapshots show operational thinking.
- Feature tags and `--mode` support are editor-friendly.

## Godot Tiny MMO Cons

- Much larger and harder to reason about than this spike.
- Current docs are behind current source.
- No formal automated test suite was found.
- Gameplay scope is broad, which can obscure networking lessons.
- Custom sync is powerful but expensive to maintain.
- It does not validate the exact high-level `MultiplayerSpawner` and
  `MultiplayerSynchronizer` path this project is testing.
- Chat is integrated into the world server, so it does not directly prove an
  independent chat connection surviving world-server peer replacement.
- Some security-sensitive demo code should not be copied directly into a real
  project.

## Worth Implementing In This Project

The following ideas are worth considering because they preserve the spike's
minimal shape:

1. Add optional config-file support for host and port values.
2. Add route refresh or reconnect-friendly route lookup so worlds can register
   after a client starts.
3. Add tiny world heartbeat metadata such as population and world name.
4. Add an optional `--mode` alias or feature-tag fallback for editor convenience.
5. Add a clearer transfer handshake around unload, connect, ready, and spawn.
6. Keep documenting authority rules for player movement and transfer state.

These should be small additions only if they support testing or learning. They
should not turn this spike into a framework.

## Keep Out Of Scope For This Project

The following Godot Tiny MMO ideas are important but should remain out of scope
for this small test:

- SQLite persistence.
- Authentication.
- Account creation.
- Guest login.
- Character selection.
- Gateway HTTP API.
- Dashboard and moderation tools.
- Custom `PackedByteArray` synchronization.
- Interest management and AOI.
- Guilds, parties, inventory, combat, quests, or NPC systems.
- Production server orchestration.
- TLS, reverse proxy, or public deployment concerns.

These are good future spikes. They are not needed to answer whether a Godot
client can keep chat connected while swapping world server connections with
high-level multiplayer nodes.

## Future MMO Research Plan

Recommended follow-up spikes:

1. Keep this project as the high-level-node baseline.
2. Create a separate gateway/auth spike inspired by Godot Tiny MMO's
   gateway-master-world token flow.
3. Create a tiny SQLite persistence spike with one character table and one last
   world field.
4. Create an instance-manager spike that borrows the idea of explicit map
   resources and a ready-to-enter handshake.
5. Create a custom-sync research spike only after the high-level
   `MultiplayerSpawner` and `MultiplayerSynchronizer` limits are clearly hit.
6. Compare bandwidth and authority tradeoffs between Godot high-level nodes and
   a Tiny MMO style byte codec.

## Final Recommendation

Keep this project's current architecture for the MVP.

Godot Tiny MMO is better treated as a long-term reference than as a direct
implementation target. It is valuable because it shows what a Godot MMO can grow
into, but the current project has a different research question:

- Can one client keep multiple Godot multiplayer contexts alive?
- Can chat stay connected while the active world peer changes?
- Can high-level RPCs and `MultiplayerSpawner` support the smallest useful
  version of server travel, while `MultiplayerSynchronizer` remains available
  for manual live movement validation?
- Can all roles live in one project and be exported, launched, and tested?

The current setup answers those questions more directly than a larger
gateway/auth/database framework would.
