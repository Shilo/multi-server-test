# End-To-End Validation Findings

Historical note: this document records the validation state from an earlier spike checkpoint on 2026-06-05. The current implementation has since added `MultiplayerSpawner` to `client/world/world.tscn` and `MultiplayerSynchronizer` position replication to `client/player/Player.tscn`. Treat `docs/mini-mmo-architecture-guide.md` as the canonical current architecture.

Date: 2026-06-05

## Purpose

This document captures the final implementation and validation state for the minimal Godot 4 native multiplayer multi-server spike.

The specific validation question was:

Can real Godot clients connect to a master server, persistent chat server, and multiple world servers, then transfer between world servers while chat remains connected?

Answer: yes, in this MVP shape.

## Implementation Summary

The project is still one Godot 4.6 project with role-selected startup:

- `--role master`
- `--role chat`
- `--role world --world 1`
- `--role world --world 2`
- `--role world --world 3`
- `--role client`

Roles:

- Master server accepts route requests and maintains a live registry of world servers.
- Chat server accepts client chat RPCs and echoes messages.
- World servers accept gameplay/world clients and authorize portal transfers.
- Each world server also opens a separate master-registration connection.
- Client opens separate multiplayer contexts for master, chat, and active world.

Client branch contexts:

- `MasterNet/MasterEndpoint`
- `ChatNet/ChatEndpoint`
- `WorldNet/WorldEndpoint`

World server branch contexts:

- `WorldNet/WorldEndpoint` for client/world traffic.
- `MasterNet/MasterEndpoint` for world-to-master registration.

This keeps chat and control-plane networking separate from swappable world networking.

## Current Server Orchestration Behavior

The master no longer only returns static route constants.

Startup sequence:

1. Master starts and listens on `ws://127.0.0.1:19080`.
2. Chat starts and listens on `ws://127.0.0.1:19081`.
3. World 1 starts on `ws://127.0.0.1:19082`.
4. World 1 registers with master as world `1`.
5. World 2 starts on `ws://127.0.0.1:19083`.
6. World 2 registers with master as world `2`.
7. World 3 starts on `ws://127.0.0.1:19084`.
8. World 3 registers with master as world `3`.
9. Client asks master for routes.
10. Master replies with the live world registry.

The smoke harness waits for:

- `MASTER_READY`
- `CHAT_READY`
- `WORLD_READY id=1`
- `WORLD_READY id=2`
- `WORLD_READY id=3`
- `MASTER_WORLD_REGISTERED id=1`
- `MASTER_WORLD_REGISTERED id=2`
- `MASTER_WORLD_REGISTERED id=3`

Only then does it launch smoke clients.

## Current Travel Behavior

The client starts in World 1.

Each smoke client executes:

1. Connect to master.
2. Receive live routes.
3. Disconnect master.
4. Connect chat.
5. Send initial chat ping.
6. Connect World 1.
7. Transfer World 1 -> World 2.
8. Send chat ping.
9. Transfer World 2 -> World 1.
10. Send chat ping.
11. Transfer World 1 -> World 3.
12. Send chat ping.
13. Transfer World 3 -> World 1.
14. Send chat ping.
15. Exit with `SMOKE_PASS`.

The active world connection is replaced by setting the world branch peer offline, loading the target world scene, then connecting to the target world server.

The chat branch is not touched during world transfer.

## Manual Runtime Decoupling

Outside of `--smoke-test`, the client no longer requires the complete world graph or chat server.

Manual mode requires:

- Master server.
- Initial world route from master.
- The initial world server.

Manual mode treats these as optional:

- Chat server.
- World 2.
- World 3.

If chat is unavailable, the client logs that optional chat is unavailable and continues.

If a world is not registered with master, portals to that world are hidden when the local world scene is built. This lets a developer run only:

```text
-- --role master
-- --role world --world 1
-- --role client
```

and still visually debug the client in World 1.

Smoke mode remains strict and continues to require chat plus all three worlds.


## High-Level Multiplayer Node Findings

The current MVP does not use `MultiplayerSpawner` or `MultiplayerSynchronizer`; it uses explicit RPC endpoints.

Research found that this is the correct MVP choice because:

- It directly proves separate branch peers and world-server travel.
- It avoids mixing server-travel research with replication-node correctness.
- Godot high-level replication nodes require stricter scene-tree and authority discipline.

If this spike evolves to high-level multiplayer nodes:

- Do not carry live synchronized nodes from one server connection to another.
- Treat world-server travel as teardown/rebuild of the entire replicated `WorldNet` branch.
- Set the branch `MultiplayerAPI` before spawners/synchronizers enter or become ready.
- Use a server-authority `MultiplayerSpawner` to spawn the level and player nodes.
- Keep `ChatNet` and master/control-plane branches outside the replicated world branch.
- Avoid `change_scene_to_file()` for a connected replicated world. Use spawner-owned level children instead.
- Reassign authority after each connection because peer IDs belong to the current server.

## Test Harness Changes

`tools/run_smoke.ps1` now supports:

```powershell
-ClientCount <n>
```

For `ClientCount > 1`, it launches `client1`, `client2`, etc. simultaneously against the same master, chat, and world servers.

The harness verifies:

- Every client produces `SMOKE_PASS`.
- Master, chat, and all three world servers are ready.
- All three worlds registered with master.
- Chat server received at least `5 * ClientCount` chat messages.

The client smoke chat messages are now unique per transfer step. This fixed a test hole where repeated World 1 chat labels could make a later chat check pass from an earlier echo.

## End-To-End Test Matrix

All tests were run locally with Godot `4.6.3.stable.official.7d41c59c4`.

Commands:

```powershell
& "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe" --headless --path . --check-only --script res://client/client_main.gd
powershell -ExecutionPolicy Bypass -File tools\run_smoke.ps1 -ClientCount 2 -TimeoutSeconds 60
powershell -ExecutionPolicy Bypass -File tools\export_all.ps1
powershell -ExecutionPolicy Bypass -File tools\run_smoke.ps1 -UseExported -ClientCount 2 -TimeoutSeconds 60
```

Heavy repeated validation:

```powershell
# 3 editor/headless runs, 2 clients each
powershell -ExecutionPolicy Bypass -File tools\run_smoke.ps1 -ClientCount 2 -TimeoutSeconds 60

# 3 exported-artifact runs, 2 clients each
powershell -ExecutionPolicy Bypass -File tools\run_smoke.ps1 -UseExported -ClientCount 2 -TimeoutSeconds 60

# 1 exported-artifact run, 3 clients
powershell -ExecutionPolicy Bypass -File tools\run_smoke.ps1 -UseExported -ClientCount 3 -TimeoutSeconds 75
```

Results:

- Partial manual topology with master + World 1 + client: pass.
- Manual portal topology with master + World 1 + World 2 + client, no chat: pass.
- Editor/headless two-client smoke: pass.
- Exported two-client smoke: pass.
- 3 repeated editor/headless two-client runs: pass.
- 3 repeated exported two-client runs: pass.
- Exported three-client run: pass.

Final exported three-client run summary:

- `SMOKE_PASS clients=3 chat_messages=15`
- Master saw `MASTER_WORLD_REGISTERED id=1`, `id=2`, `id=3`.
- Master served three client route requests with `registered_worlds=3`.
- Chat received 15 messages, which is 5 messages per client.
- World 1 saw three transfer requests to World 2 and three transfer requests to World 3.
- World 2 saw three transfer requests back to World 1.
- World 3 saw three transfer requests back to World 1.
- Each of `client1`, `client2`, and `client3` confirmed:
  - initial World 1
  - World 2 with chat alive
  - World 1 with chat alive
  - World 3 with chat alive
  - final World 1 with chat alive
  - `SMOKE_PASS`

## What This Proves

- Multiple clients can connect to the same master server.
- Multiple clients can connect to the same chat server.
- Multiple clients can connect to the same world servers.
- World servers can register with master before clients route.
- Master can return live registered world endpoints.
- Clients can transfer between separate world server processes.
- Chat remains connected during world transfer.
- Separate branch-local multiplayer contexts work for this architecture.
- Exported artifacts run the same topology successfully.

## What This Does Not Prove Yet

- Production auth, tickets, or secure transfer authorization.
- Persistence of player state across world servers.
- Server-side player simulation or replication.
- `MultiplayerSpawner`/`MultiplayerSynchronizer` travel correctness.
- Cloud orchestration, autoscaling, allocation, or Docker/Agones integration.
- Packet loss, latency, reconnect, or crash recovery behavior.

These are intentionally outside the MVP.
