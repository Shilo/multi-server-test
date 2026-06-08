# End-To-End Validation Findings

Date: 2026-06-08

This document records the current validation state after the three-role refactor.

## Question

Can real Godot clients connect to a master server, master-hosted chat endpoint, and multiple Godot headless world servers, then transfer between world servers while chat remains connected?

Answer: yes, in the current small-scale spike shape.

## Current Roles

- `client`: visible or headless game client.
- `master_server`: world registry, route snapshot, transfer approval, and chat host.
- `world_server`: gameplay process for one world key.

There is no standalone gateway, chat process, auth server, database, persistence layer, or orchestration layer in this refactor.

## Current Launch Shape

Editor-binary smoke and CI launch direct scenes:

```text
res://master_server/master_server.tscn
res://world_server/world_server.tscn -- hub
res://world_server/world_server.tscn -- left_world
res://world_server/world_server.tscn -- right_world
res://client/client.tscn -- smoke_test
```

Normal/editor/export workflow uses feature tags through `res://shared/main/main.tscn`. Exported smoke runs the role-tagged artifacts directly.

## Validated Markers

The automated editor-binary smoke test passed with:

```text
MASTER_READY
WORLD_READY key=hub
WORLD_REGISTERED key=hub
WORLD_READY key=left_world
WORLD_REGISTERED key=left_world
WORLD_READY key=right_world
WORLD_REGISTERED key=right_world
MASTER_WORLD_REGISTERED key=hub
MASTER_WORLD_REGISTERED key=left_world
MASTER_WORLD_REGISTERED key=right_world
SMOKE_PASS clients=2 chat_messages=10
```

Exported smoke also passed with:

```text
SMOKE_PASS clients=1 chat_messages=5
```

The smoke sequence transferred:

```text
hub -> left_world -> hub -> right_world -> hub
```

Chat stayed connected across the active `WorldNet` swaps.

## Argument Validation

World startup argument behavior was checked directly:

- no user argument starts `hub`;
- invalid world key exits with code `12`;
- more than one user argument exits with code `14`.

The only supported world selection syntax is a bare positional world key after Godot's `--`.

## Godot Checks

The following scenes and scripts passed `--check-only`:

- `res://shared/main/main.tscn`
- `res://client/client.tscn`
- `res://master_server/master_server.tscn`
- `res://world_server/world_server.tscn`
- `res://shared/main/main.gd`
- `res://client/client.gd`
- `res://master_server/master_server.gd`
- `res://world_server/world_server.gd`
- `res://shared/net/master_endpoint.gd`
- `res://shared/net/chat_endpoint.gd`
- `res://shared/net/world_endpoint.gd`
- `res://shared/world/world.gd`
- `res://shared/world/portal_area.gd`
- `res://shared/player/player.gd`

`git diff --check` also passed.

## Remaining Manual Verification

The smoke test validates registration, chat, travel, and branch reconnection. Manual two-client Run Instances testing is still useful for visually inspecting replicated player spawn/despawn and live movement synchronization.
