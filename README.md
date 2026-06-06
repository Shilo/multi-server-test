# Minimal Godot 4 Multi-Server Multiplayer Spike

This is a one-project Godot 4.6 MVP proving a native multiplayer topology with:

- One client.
- One master server.
- One chat server.
- Three world servers.
- WebSocket-based `MultiplayerAPI` peers.
- Separate client multiplayer contexts for master, chat, and active world.
- A persistent chat connection while the active world connection is replaced.
- Live world registration with the master server before client route lookup.
- A tiny top-down `CharacterBody2D` player.
- Three visibly distinct worlds with portal transfer topology:
  - World 1 -> World 2
  - World 2 -> World 1
  - World 1 -> World 3
  - World 3 -> World 1

This is intentionally a spike, not a production framework.

## Structure

- `launcher/`: the one main scene. It reads `--role`.
- `client/`: client root, player, world scenes, and portals.
- `server/master/`: master route server.
- `server/chat/`: separate chat server.
- `server/world/`: shared world server role, configured by `--world`.
- `shared/`: shared endpoints, config, and CLI parsing.
- `tools/`: export and smoke-test scripts.
- `docs/`: research and audit notes.

The client uses sibling networking branches:

- `MasterNet/MasterEndpoint`
- `ChatNet/ChatEndpoint`
- `WorldNet/WorldEndpoint`

Those names are mirrored in the server scenes so RPC paths and scripts match.

World servers also use a separate `MasterNet/MasterEndpoint` branch to register with master while their `WorldNet/WorldEndpoint` branch accepts gameplay clients.

World scene inheritance:

- `client/world/world.tscn` is the shared base world scene.
- `client/world/world_1.tscn`, `world_2.tscn`, and `world_3.tscn` inherit from it and only override identity, color, and portal targets.
- Add shared world-level nodes, such as a `MultiplayerSpawner`, to `world.tscn` when testing high-level replication.
- Client and world server both mount the active inherited world scene at `WorldNet/WorldSceneRoot`, so branch-local multiplayer paths match below `WorldNet`.
- `world.tscn` includes `SpawnRoot`; point `MultiplayerSpawner.spawn_path` there for replicated world children.
- World servers spawn `Player_<peer_id>` instances as direct children of `SpawnRoot` when peers connect. This proves spawning only; add `MultiplayerSynchronizer` to the player scene when you want movement/property replication.

## Run Roles From The Editor Binary

Use the local Godot 4.6.3 binary:

```powershell
$godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe"
```

Launch servers:

```powershell
& $godot --headless --path . -- --role master
& $godot --headless --path . -- --role chat
& $godot --headless --path . -- --role world --world 1
& $godot --headless --path . -- --role world --world 2
& $godot --headless --path . -- --role world --world 3
```

Launch a manual client:

```powershell
& $godot --path . -- --role client
```

Manual client mode is relaxed. It requires master plus the initial registered world, but chat and other worlds are optional. If only World 1 is registered, the client enters World 1 and hides portals to unavailable worlds.

Manual portal reproduction test with only master, World 1, and World 2:

```powershell
& $godot --headless --path . -- --role master
& $godot --headless --path . -- --role world --world 1
& $godot --headless --path . -- --role world --world 2
& $godot --headless --path . -- --role client --manual-portal-test
```

Success logs include `MANUAL_PORTAL_TEST_PASS`.

## Test From Godot Run Instances

Use Godot's editor launcher when you want visible local clients and headless local servers.

Open:

```text
Debug > Customize Run Instances...
```

![Godot Run Instances configured for two clients and five headless servers](docs/images/godot-run-instances-full-topology.png)

Recommended setup for two visible clients plus the full server topology:

- Leave `Main Run Args` empty. The main run becomes one visible client.
- Enable `Enable Multiple Instances`.
- Set the instance count to `7`.
- Leave the first extra instance's `Launch Arguments` empty. This becomes the second visible client.
- Add these launch arguments for the remaining extra instances:

```text
--headless -- --role master
--headless -- --role world --world 1
--headless -- --role world --world 2
--headless -- --role world --world 3
--headless -- --role chat
```

The final run-instance table should conceptually be:

```text
main editor run: visible client
instance 1:       visible client
instance 2:       --headless -- --role master
instance 3:       --headless -- --role world --world 1
instance 4:       --headless -- --role world --world 2
instance 5:       --headless -- --role world --world 3
instance 6:       --headless -- --role chat
```

Then press Play. Expected behavior:

- Both visible clients connect to master, chat, and World 1.
- Both clients spawn `Player_<peer_id>` nodes under `SpawnRoot`.
- Chat messages sent with Enter show the sender peer id.
- A local-authority player entering a portal transfers only that client.
- Chat remains connected while the active world connection changes.

Important testing notes:

- Stop the previous run before starting another one. Otherwise old headless servers can keep ports `19080` through `19084` bound.
- Start order is handled by the client retry/wait path well enough for this spike, but if a client launches before every world registers, manual mode only sees worlds that were registered when routes were fetched.
- If you change scripts or scenes used by the headless roles, stop and restart the run instances so those server processes reload the project.
- Run-instance testing is for manual visual verification. Use `tools/run_smoke.ps1` for repeatable pass/fail automation.

## Automated Smoke Test

Editor/headless smoke:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_smoke.ps1
```

Two simultaneous editor/headless clients:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_smoke.ps1 -ClientCount 2
```

Exported-artifact smoke:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_smoke.ps1 -UseExported
```

Three simultaneous exported clients:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_smoke.ps1 -UseExported -ClientCount 3
```

Successful logs include:

- `MASTER_READY`
- `CHAT_READY`
- `WORLD_READY id=1`
- `WORLD_READY id=2`
- `WORLD_READY id=3`
- `MASTER_WORLD_REGISTERED id=1`
- `MASTER_WORLD_REGISTERED id=2`
- `MASTER_WORLD_REGISTERED id=3`
- `SMOKE_STEP client connected to chat`
- `SMOKE_STEP client confirmed initial world 1`
- `SMOKE_STEP confirmed world 2 with chat alive`
- `SMOKE_STEP confirmed world 1 with chat alive`
- `SMOKE_STEP confirmed world 3 with chat alive`
- `SMOKE_PASS`

Logs are written under `.logs/` and ignored by git.

## Export

Install Godot export templates for `4.6.3.stable` first if needed. The export script expects Windows Desktop templates at Godot's normal template path.

Export all role-labeled artifacts:

```powershell
powershell -ExecutionPolicy Bypass -File tools\export_all.ps1
```

Outputs:

- `builds/client/client.exe`
- `builds/master/master.exe`
- `builds/chat/chat.exe`
- `builds/world1/world1.exe`
- `builds/world2/world2.exe`
- `builds/world3/world3.exe`

Each artifact is the same shared Godot project with a different filename. Role behavior still comes from `--role` and `--world`, which keeps the MVP simple and proves shared-project export without multiplying projects.

## Research Findings

Research notes:

- `docs/spike-findings.md`
- `docs/research-sweep.md`
- `docs/server-orchestration-and-travel.md`
- `docs/end-to-end-validation.md`

Important Godot limitations discovered:

- Custom multiplayer branches cannot be nested.
- RPC paths, node names, RPC annotations, and script signatures must match.
- Client-to-server RPCs need `@rpc("any_peer")`.
- Branch-local multiplayer works for separate contexts, but connection status checking was more reliable than relying only on `connected_to_server` signals in this smoke.
- If this spike later uses `MultiplayerSpawner` and `MultiplayerSynchronizer`, server travel should fully tear down and rebuild the active replicated world branch. Do not carry live synchronized nodes from one server peer to another.
- Godot 4 dedicated server execution uses `--headless`; no separate Godot 3-style server binary is needed.

Runtime/testing split:

- Manual client mode: relaxed partial topology for debugging.
- `--smoke-test`: strict full topology, requiring chat and worlds 1/2/3.

MCP and local validation used:

- Godot MCP `get_project_info`.
- Godot CLI parse checks.
- Godot CLI headless role launches.
- Multi-process editor/headless smoke.
- Exported-artifact smoke.

## Next Mimic-Oriented Steps

- Turn `MasterNet`, `ChatNet`, and `WorldNet` into explicit reusable context nodes.
- Create editor-visible configuration for endpoints and allowed transfers.
- Keep RPC endpoint names stable or generate mirrored client/server scenes.
- Add a tiny test harness around branch setup timing and RPC path validation.
- Resist adding replication/prediction until the branch-context abstraction is proven.
