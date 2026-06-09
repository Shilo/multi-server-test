# End-To-End Validation Findings

Date: 2026-06-08

This document records the current validation state after the three-role refactor.

## Question

Can real Godot clients connect to a master server, cause Godot world servers to start on demand, transfer between them while chat remains connected, and let empty worlds shut down?

Answer: yes, in the current small-scale spike shape.

## Current Roles

- `client`: visible or headless game client.
- `master`: world process orchestration, world registry, route snapshot, transfer approval, and chat host.
- `world`: temporary gameplay process for one active world key.

There is no standalone gateway, chat process, auth server, database, persistence layer, Docker layer, or external fleet service in this refactor.

## Current Launch Shape

Editor-binary smoke and CI launch direct scenes:

```text
res://server/master/master.tscn
res://client/client.tscn -- smoke_test
```

Normal/editor/export workflow uses feature tags through `res://shared/main/main.tscn`. Exported smoke runs the client artifact plus one standalone server artifact, then the master creates additional instances of that same server artifact for worlds on demand.

## Validated Markers

The automated editor-binary smoke test passed with one client:

```text
MASTER_READY
MASTER_WORLD_STARTED key=hub
MASTER_WORLD_REGISTERED key=hub
MASTER_WORLD_STOP_REQUESTED key=hub reason=idle
MASTER_WORLD_STOPPED key=hub
MASTER_WORLD_STARTED key=left_world
MASTER_WORLD_REGISTERED key=left_world
MASTER_WORLD_STOP_REQUESTED key=left_world reason=idle
MASTER_WORLD_STOPPED key=left_world
MASTER_WORLD_STARTED key=right_world
MASTER_WORLD_REGISTERED key=right_world
MASTER_WORLD_STOP_REQUESTED key=right_world reason=idle
MASTER_WORLD_STOPPED key=right_world
MASTER_WORLD_STARTED key=top_world
MASTER_WORLD_REGISTERED key=top_world
MASTER_WORLD_STOP_REQUESTED key=top_world reason=idle
MASTER_WORLD_STOPPED key=top_world
SMOKE_PROCESS_GONE hub_after_master_kill
SMOKE_PASS clients=1 chat_messages=7
```

Two-client editor-binary smoke also passed with:

```text
SMOKE_PASS clients=2 chat_messages=14
```

Exported smoke also passed with:

```text
SMOKE_PASS clients=1 chat_messages=7
```

The smoke sequence transferred:

```text
hub -> left_world -> hub -> right_world -> hub -> top_world -> hub
```

Chat stayed connected across the active `WorldNet` swaps.
The smoke harness also starts a fresh master, lets it launch `hub`, kills the master process, parses the child world PID, and verifies the hub process exits.
Route and transfer approvals now emit pending-join reservations before clients connect to the target world. Clients refresh the reservation over `MasterNet` until world state is received or the join fails, preventing the idle shutdown timer from firing during a live approval-to-connect window.

## Argument Validation

World startup argument behavior was checked directly:

- no user argument on the standalone server starts master;
- no user argument on the world scene fails because worlds require explicit keys;
- invalid world key exits with code `12`;
- more than two user arguments exit with code `14`.

The world key remains a bare positional argument after Godot's `--`. Master-owned launches append a private launch token after that key so the world can register.

## Godot Checks

The following scenes and scripts passed `--check-only`:

- `res://shared/main/main.tscn`
- `res://client/client.tscn`
- `res://server/master/master.tscn`
- `res://server/world/world.tscn`
- `res://shared/main/main.gd`
- `res://client/client.gd`
- `res://server/master/master.gd`
- `res://server/world/world.gd`
- `res://shared/net/master_endpoint.gd`
- `res://shared/net/chat_endpoint.gd`
- `res://shared/net/world_endpoint.gd`
- `res://shared/world/world.gd`
- `res://shared/world/portal.gd`
- `res://shared/player/player.gd`

`git diff --check` also passed.

## Remaining Manual Verification

The smoke test validates registration, chat, travel, and branch reconnection. Manual two-client Run Instances testing is still useful for visually inspecting replicated player spawn/despawn and live movement synchronization.
