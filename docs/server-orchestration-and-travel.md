# Server Orchestration And Server Travel Research

Historical note: this research note captures decisions from an earlier spike checkpoint. The current implementation has since added `MultiplayerSpawner` and `MultiplayerSynchronizer` to the world/player scenes. Treat `docs/godot-multi-server-architecture-guide.md` as the canonical current architecture.

Date: 2026-06-05

## 2026-06-08 On-Demand World Orchestration Update

2026-06-14 note: the current implementation now splits travel into a
refreshable `TravelLease` for PackRat asset preparation and a short-lived
one-use join ticket for final world entry. The target world process is started
when the client redeems the TravelLease, not when the lease is first granted.

The current custom Godot branch now uses master-owned child process orchestration:

- Master is the only process expected to stay online all the time.
- World servers are temporary child processes started by master when a route or transfer needs that world.
- A world with `0` connected gameplay peers is stopped by master after the idle window.
- Route and transfer approvals create pending-join reservations that clients refresh over `MasterNet`, so an empty world is not stopped while an approved client is still connecting.
- Route and transfer approvals also issue short-lived one-use join tickets. Worlds only spawn a master-launched client after that ticket is presented, which prevents raw direct joins to active world ports.
- Master records the child PID and kills it if graceful shutdown does not complete.
- World servers still self-exit if they were launched by master and then lose the master connection for the cleanup window.
- World servers only become registered after master ACKs their launch token. A rejected or unacknowledged registration exits instead of holding a port forever.
- Repeated route or transfer interest does not extend an empty world's idle lifetime; only a real gameplay peer connection cancels the idle countdown.

This hybrid is intentional. If worlds decide their own lifetime, lifecycle policy gets scattered across every gameplay process. If only master handles shutdown, additional Godot instances can survive a master crash because Godot starts them independently. The combined design keeps allocation policy centralized in master while still cleaning up orphaned worlds during local testing and simple VPS operation.

The old `WORLD_REGISTRATION_SECRET` was removed. A shared secret in `shared/net/net_config.gd` is not a real trust boundary because shared scripts are included in client exports. Master now generates a per-launch token and passes it only to the child world process. Registration is accepted only if the world key and token match a process master actually started.

The launch token is still passed as a process argument. That is acceptable for this local/single-user spike, but it is not a strong boundary on a shared multi-user host because process arguments may be inspectable. Before public/shared-host deployment, replace it with a short-lived loopback handshake, pipe, or another channel with OS-level access control.

Relevant Godot constraints:

- Godot custom feature tags are export-time tags; they are not injected by normal editor CLI launches. Editor/smoke world children therefore launch with the current Godot executable plus `--path`, `--scene`, and `-- <world_key> <launch_token>`.
- Exported server builds launch another instance of the same standalone server executable with `-- <world_key> <launch_token>`.
- Master-owned world launches inherit the master's display mode. A visible editor/debug master spawns visible world windows; a headless master spawns headless world processes.
- `OS.create_instance()` returns a PID and launches another Godot instance independently; it does not create a child that automatically dies with the parent.
- `OS.kill()` and `OS.is_process_running()` are the practical minimal tools for local child supervision.

For production, the next hardening step is not a separate allocator yet. Run the master under a normal service supervisor such as systemd, keep world allocation in master, and add remote-host configuration plus authenticated server-side transfer/session tickets before public testing.

## What Was Researched

- How Godot projects commonly split client, master/lobby/matchmaking, and dedicated world/session servers.
- How production-oriented Godot server setups treat orchestration, registration, health, and allocation.
- How Godot's high-level multiplayer branch APIs affect a client connected to multiple services.
- How `MultiplayerSpawner` and `MultiplayerSynchronizer` affect travel between servers.
- Whether the current spike should keep static routes or make world servers register with master.

## Official Godot Findings

- Godot's high-level multiplayer lives on the `SceneTree`. Every node has a `multiplayer` property, and a custom `MultiplayerAPI` can be assigned to a `NodePath`; Godot explicitly calls out sibling nodes using different peers as valid.
- `SceneTree.set_multiplayer()` rejects nested custom multiplayer branches. It should be set before multiplayer-aware children are ready, especially when using `MultiplayerSpawner` and `MultiplayerSynchronizer`.
- `WebSocketMultiplayerPeer` is a `MultiplayerPeer` usable by `MultiplayerAPI`, with `create_client(url)` and `create_server(port, bind_address)`. URLs should include `ws://` or `wss://`.
- If client and server live in one Godot project, Godot's dedicated-server docs recommend command-line arguments to start server code from the same project.
- Godot 4 dedicated servers can run with `--headless`; a separate Godot 3-style server binary is not required.
- `MultiplayerSpawner` replicates spawnable nodes from authority to peers and can replicate late joins/reconnects.
- `MultiplayerSynchronizer` synchronizes configured properties from multiplayer authority to remote peers.
- Godot's scene-replication article warns that changing scenes during a multiplayer session can be problematic; the recommended high-level-node pattern is spawning/removing the level scene through a `MultiplayerSpawner`, not blindly calling `change_scene*`.

## Community And Prior-Art Findings

- W4 Cloud's dedicated-server model is built on Agones concepts: a game server is one exported Godot instance for one match/session; fleets are pools of those instances; regions and buffers control allocation.
- Godot-oriented hosting guides generally separate three layers:
  - Game client.
  - Headless dedicated Godot server.
  - Platform backend or master service for auth, matchmaking, registry, allocation, and persistence.
- Practical server-browser approaches have each game/world server register its address, map/world, and player counts with a backend, then heartbeat periodically.
- Matchmaker/orchestrator approaches allocate or spin up a server and return endpoint info to the client.
- Community Godot discussion around multiple maps/worlds commonly recommends multiple server instances, one per map/world/session, when worlds are meaningfully separated.
- Community discussion around orchestration also warns that full cloud orchestration is overkill for early spikes; local process orchestration and a tiny registry are enough to prove the architecture.

## High-Level Multiplayer Node Travel Findings

The current spike uses explicit RPC endpoints rather than `MultiplayerSpawner`/`MultiplayerSynchronizer`. That is acceptable for the MVP.

If this evolves to high-level replicated nodes, server travel should follow stricter rules:

- Treat travel as a full teardown/rebuild of the world multiplayer branch.
- Keep chat and master/control-plane branches outside the world branch.
- Before connecting to a new world server, remove or despawn replicated children under the old world branch.
- Set `world_api.multiplayer_peer = OfflineMultiplayerPeer.new()` before attaching the new peer.
- Rebuild the replicated world branch from scenes with the same node names and paths on client and server.
- Ensure `SceneTree.set_multiplayer()` is already configured for the branch before `MultiplayerSpawner` or `MultiplayerSynchronizer` nodes enter or become ready.
- Let the server authority spawn the level and player nodes through `MultiplayerSpawner`.
- Avoid `get_tree().change_scene_to_file()` for the replicated world during a connected session; use a spawner-controlled level child instead.
- Reassign authority deterministically after reconnect, because peer IDs and node authorities belong to the current server connection.
- Do not try to carry live synchronized nodes from one server peer to another. Serialize the transfer state and let the target server respawn/authorize it.

## Current Spike Assessment

What is still good:

- One project with role-selected startup remains the simplest Godot-native MVP path.
- Separate sibling branches for master, chat, and world match Godot's custom `MultiplayerAPI` model.
- Three separate world server processes are the right shape for a multi-world/server-transfer spike.
- Explicit RPC endpoints are simpler than high-level replication nodes for proving cross-server travel.

What should change:

- Master should not only return static world constants. Even in an MVP, world servers should prove they can announce themselves to the master.
- The smoke harness should wait for server readiness markers instead of sleeping a fixed time before starting the client.
- Smoke validation should assert that all worlds registered with master before client route lookup.

What should not change yet:

- Do not introduce Docker, Kubernetes, Agones, W4, Nakama, PlayFab, auth, ticketing, or a database.
- Do not convert the spike to `MultiplayerSpawner`/`MultiplayerSynchronizer` yet. That would answer a different, larger question.
- Do not build a generic Mimic abstraction yet.

## Decision

Keep the current single-project, role-argument, multi-process topology.

Add one minimal orchestration behavior:

- Each world server opens a separate master-registration multiplayer context.
- Each world server registers its world ID and endpoint with master.
- Master responds to client route requests using live registered world endpoints.
- The smoke script waits for `MASTER_WORLD_REGISTERED id=1`, `id=2`, and `id=3` before launching the client.

This preserves the MVP while making the master/world relationship much closer to how real server registries and allocators work.
