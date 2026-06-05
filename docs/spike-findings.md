# Godot 4 Multi-Server Multiplayer Spike Findings

Runtime checked locally through Godot MCP:

- Godot version: `4.6.3.stable.official.7d41c59c4`
- Project: one Godot project at `C:\Programming_Files\Shilocity\Godot\Tests\multi-server-test`
- MCP tools used during research: `mcp__godot.get_project_info`, local shell commands, and official Godot documentation lookup.

## Official Documentation Findings

- `WebSocketMultiplayerPeer` is a `MultiplayerPeer` implementation for the high-level `MultiplayerAPI`. It supports `create_server(port, bind_address)` and `create_client(url)`, and Godot recommends URL schemes such as `ws://`.
- A `MultiplayerPeer` is assigned to a `MultiplayerAPI` by setting `multiplayer.multiplayer_peer`.
- `SceneTree.set_multiplayer(multiplayer_api, root_path)` can override the multiplayer API used by a specific scene-tree branch.
- Nested custom multiplayer branches are explicitly not allowed. If a branch has a custom `MultiplayerAPI`, a child subpath cannot have another custom `MultiplayerAPI`.
- `set_multiplayer()` should be called before multiplayer-aware children under that root are ready.
- RPC calls require matching node paths and node names on both peers. When nodes are added dynamically for RPC use, readable/stable names matter.
- RPC declarations must match on client and server scripts. Mismatched RPC annotations/signatures can produce confusing errors.
- Dedicated servers can run through `--headless`; Godot 4 no longer requires a separate special server binary.
- If client and server live in one project, Godot's dedicated server docs recommend using command-line arguments or feature tags to choose server startup code.
- CLI export supports presets through `--export-release`, `--export-debug`, and `--export-pack`.
- `CharacterBody2D` top-down movement should use `_physics_process()` and `move_and_slide()`/`move_and_collide()`, with no gravity needed for this spike.

## Spike Questions Answered

Can one Godot client maintain multiple native multiplayer connections at once?
: Yes, by creating separate `MultiplayerAPI` instances and assigning them to separate, non-nested scene branches.

Can separate scene tree branches use separate multiplayer APIs safely?
: Yes, this is an intended use of `SceneTree.set_multiplayer()`.

Are nested multiplayer branches allowed or problematic?
: Nested custom multiplayer branches are not allowed. The MVP keeps `MasterNet`, `ChatNet`, and `WorldNet` as siblings.

What scene tree structure is most reliable for separating chat and world networking?
: A single client scene with sibling branch roots:
`/ClientRoot/MasterNet`, `/ClientRoot/ChatNet`, and `/ClientRoot/WorldNet`.

What limitations exist around RPC node paths, node names, and authority?
: RPC scripts and node paths must match on both peers. The server is authority by default. Client-to-server calls need `@rpc("any_peer")`. Dynamically added RPC nodes need stable names.

What happens when the active world peer is replaced while chat remains alive?
: Replacing only the `WorldNet` branch peer leaves `ChatNet` untouched, because they use separate `MultiplayerAPI` instances.

Does the client need a separate master connection after initial routing?
: No. For this MVP, master is queried at startup, then disconnected. Chat persists; world swaps.

Can multiple Godot client/server roles share one project?
: Yes. Use a launcher scene and role-specific command-line arguments.

What is the cleanest way to launch a role-specific scene or mode from CLI?
: One main launcher scene reads `--role`, `--world`, and `--smoke-test` from `OS.get_cmdline_user_args()`.

What is the cleanest way to export every role from the same project?
: Use one export preset for the shared project artifact and role-specific wrapper scripts/commands. The exported binary receives the same role arguments.

What is the simplest reliable smoke test strategy?
: A PowerShell orchestrator starts five headless servers and one headless scripted client, captures logs, waits for a `SMOKE_PASS` marker, then terminates remaining processes.

What is the simplest reliable top-down `CharacterBody2D` scene setup?
: A `CharacterBody2D` with a `Sprite2D` using `res://icon.svg`, a small `CollisionShape2D`, input-vector movement, and `move_and_slide()`.

What is the simplest reliable portal-triggered world transfer setup?
: Client-visible `Area2D` portals call a client transfer method. The world server exposes an RPC that accepts allowed target worlds and replies with the target world endpoint.

## Brainstormed Structures

### Option 1: One launcher scene with role-specific root scripts

- Minimalism: High. One entry point, explicit `--role`.
- Testing: High. Smoke scripts can launch the same project repeatedly with different args.
- Shared code: High. All scripts live in one project and import shared constants/helpers.
- Role separation: Good if folders are explicit.
- CLI export: Simple. One exported artifact can run any role; wrappers provide role commands.
- Multi-process launch: Simple. Same binary, different args.
- Smoke testing: Simple log-based orchestration.
- Future Mimic-style extension: Good. Branch-local networking maps cleanly to future drag-and-drop network contexts.

### Option 2: Separate main scenes per role

- Minimalism: Medium. More scenes and export presets to maintain.
- Testing: Good. `--scene` can launch specific role scenes.
- Shared code: Good.
- Role separation: Excellent.
- CLI export: Medium. Presets can become repetitive.
- Multi-process launch: Good.
- Smoke testing: Good.
- Future Mimic-style extension: Good, but role scenes can hide the shared topology.

### Option 3: One scene running all roles in-process for spike, plus later process split

- Minimalism: Low for this goal. It proves branch APIs, but not dedicated server processes.
- Testing: High for API experiments, weak for architecture acceptance.
- Shared code: High.
- Role separation: Weak.
- CLI export: Weak.
- Multi-process launch: Weak.
- Smoke testing: Easy but not representative.
- Future Mimic-style extension: Useful as a lab, not as the MVP.

## Chosen Approach

Use Option 1.

The project has one launcher scene, explicit role directories, and one shared code folder. The client uses sibling multiplayer branches for master, chat, and world. Master is short-lived after startup routing; chat remains connected; world is replaced during portal transfers.

This is the smallest design that still proves the critical architecture.

