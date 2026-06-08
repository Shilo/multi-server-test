# Minimal Godot 4 Three-Role Multiplayer Spike

This is a one-project Godot 4.6 spike proving a small online-world topology with:

- One client role.
- One master server role.
- One world server role, started once per world key.
- Chat hosted by the master server on a separate `ChatNet` branch.
- Native Godot high-level multiplayer over `WebSocketMultiplayerPeer`.
- Separate client multiplayer contexts for master, chat, and the active world.
- A persistent chat connection while the active world connection is replaced.
- Server-authority player spawn/despawn with client-authority movement.
- Three visibly distinct worlds:
  - `hub`
  - `left_world`
  - `right_world`

Portal topology:

- `hub -> left_world`
- `hub -> right_world`
- `left_world -> hub`
- `right_world -> hub`

For the full walkthrough, read [Godot Multi-Server Architecture Guide](docs/godot-multi-server-architecture-guide.md).

## Structure

- `shared/main/`: feature-tag bootstrap scene.
- `client/`: playable client root and UI.
- `master_server/`: master server scene and script. Hosts `MasterNet` and `ChatNet`.
- `world_server/`: world server scene and script.
- `shared/net/`: endpoint scripts and keyed network config.
- `shared/world/`: world scenes and portal logic.
- `shared/player/`: replicated player scene and script.
- `tools/`: export and smoke-test scripts.
- `docs/`: architecture, research, and audit notes.
- `editor/run_instance_grid.gd`: editor-only autoload that tiles visible Run Instances windows for manual debugging. Production exports exclude `editor/*` and the export script temporarily removes this autoload while building.

Main documentation:

- [Godot Multi-Server Architecture Guide](docs/godot-multi-server-architecture-guide.md): canonical current architecture.
- [VirtuCade Custom Godot, SQLite, And PocketBase Decision Challenge](docs/virtucade-custom-godot-sqlite-pocketbase-decision.md): custom infrastructure decision spike.
- [Godot Tiny MMO Comparison Research](docs/godot-tiny-mmo-comparison.md): Tiny MMO comparison and lessons.
- [Godot Resource Database Wrapper Spike](docs/godot-resource-database-wrapper-spike.md): Resource-file persistence challenge spike.
- [Nakama And Godot World Server Viability Research](docs/nakama-godot-world-server-viability.md): Nakama viability research.
- [Nakama MVP Glue](docs/nakama-mvp.md): archived notes for the separate Nakama branch.

## Role Selection

Normal/editor/export workflow uses Godot feature tags:

- `master_server`: starts `res://master_server/master_server.tscn`
- `world_server`: starts `res://world_server/world_server.tscn`
- no role feature tag: starts `res://client/client.tscn`

The main scene is:

```text
res://shared/main/main.tscn
```

If both `master_server` and `world_server` feature tags are present, startup fails clearly. The app does not support role or mode command-line flags.

For smoke tests and CI, launch role scenes directly with Godot's built-in `--scene` option.

## World Keys

World selection uses exactly one syntax: a bare positional key after Godot's `--`.

Examples:

```powershell
& $godot --headless --path . --scene res://world_server/world_server.tscn -- hub
& $godot --headless --path . --scene res://world_server/world_server.tscn -- left_world
& $godot --headless --path . --scene res://world_server/world_server.tscn -- right_world
```

If no world key is provided, the world server starts `hub`. If more than one user argument is provided, or if the key is unknown, startup fails clearly.

## Manual CLI Run

Use the local Godot binary:

```powershell
$godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe"
```

Start servers in separate terminals:

```powershell
& $godot --headless --path . --scene res://master_server/master_server.tscn
& $godot --headless --path . --scene res://world_server/world_server.tscn -- hub
& $godot --headless --path . --scene res://world_server/world_server.tscn -- left_world
& $godot --headless --path . --scene res://world_server/world_server.tscn -- right_world
```

Launch a manual client:

```powershell
& $godot --path . --scene res://client/client.tscn
```

Manual client mode requires master plus the initial registered world. Chat and non-initial worlds can be missing while debugging; portals to unavailable worlds are hidden.

## Editor Run Instances

Use Godot's editor launcher when you want visible local clients and headless local servers.

Open:

```text
Debug > Customize Run Instances...
```

Recommended setup for two visible clients plus the full server topology:

- Main editor run: visible client with no launch arguments.
- Extra instance 1: visible client with no launch arguments.
- Extra instance 2: headless master using the `master_server` feature tag.
- Extra instance 3: headless world using the `world_server` feature tag and `-- hub`.
- Extra instance 4: headless world using the `world_server` feature tag and `-- left_world`.
- Extra instance 5: headless world using the `world_server` feature tag and `-- right_world`.

Stop the previous run before starting another one so old processes do not keep ports `19080` through `19084` bound.

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

Successful logs include:

- `MASTER_READY`
- `CHAT_READY`
- `WORLD_READY key=hub`
- `WORLD_READY key=left_world`
- `WORLD_READY key=right_world`
- `MASTER_WORLD_REGISTERED key=hub`
- `MASTER_WORLD_REGISTERED key=left_world`
- `MASTER_WORLD_REGISTERED key=right_world`
- `SMOKE_PASS`

Logs are written under `.logs/` and ignored by git.

## Export

Install Godot export templates for `4.6.3.stable` first if needed.

Export all role-labeled artifacts:

```powershell
powershell -ExecutionPolicy Bypass -File tools\export_all.ps1
```

Outputs:

- `builds/client/client.exe`
- `builds/client/client.pck`
- `builds/master_server/master_server.exe`
- `builds/master_server/master_server.pck`
- `builds/world_server/world_server.exe`
- `builds/world_server/world_server.pck`

There is only one world server executable. It contains all world scenes, and each process selects `hub`, `left_world`, or `right_world` with the bare world key argument.

The export script uses three Windows Desktop presets:

- `Windows Client`: no role feature tag.
- `Windows Master Server`: `master_server` feature tag.
- `Windows World Server`: `world_server` feature tag.

Smoke/CI launches scenes directly when testing from the editor binary. Exported smoke runs the role-tagged artifacts directly.

## Current Limits

- No auth.
- No database.
- No persistence.
- No transfer tickets.
- No standalone gateway.
- No standalone chat process.
- No production orchestration.
- No server-side movement validation.

The purpose of this branch is to keep the workflow small while preserving the important production-shaped boundary: master owns control/chat approval, world servers own gameplay simulation, and clients keep separate master/chat/world multiplayer branches.
