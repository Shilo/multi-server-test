# Research Sweep: Minimal Godot 4 Multi-Server MVP

Historical note: this research sweep records the state before later implementation milestones. Export tooling, exported smoke testing, `MultiplayerSpawner`, and `MultiplayerSynchronizer` are now present. Treat `docs/godot-multi-server-architecture-guide.md` as the canonical current architecture.

Date: 2026-06-05

## What Was Researched

- Godot 4 high-level/native multiplayer flow.
- `MultiplayerAPI`, `SceneMultiplayer`, and `SceneTree.set_multiplayer`.
- `WebSocketMultiplayerPeer` client/server setup.
- Multiple simultaneous multiplayer peers in one client.
- Separate scene-tree branches as separate multiplayer contexts.
- RPC node path, node name, script signature, and authority requirements.
- One-project client/server role organization.
- Dedicated server and headless execution.
- CLI role launching and export commands.
- Automated multi-process smoke testing.
- Minimal top-down `CharacterBody2D` movement.
- Minimal portal-triggered transfer flow.
- Whether the current implementation should be kept, adjusted, or refactored.

## Official Godot References Checked

- Godot 4.6 high-level multiplayer:
  `https://docs.godotengine.org/en/4.6/tutorials/networking/high_level_multiplayer.html`
- `MultiplayerAPI`:
  `https://docs.godotengine.org/en/4.6/classes/class_multiplayerapi.html`
- `SceneTree.set_multiplayer`:
  `https://docs.godotengine.org/en/stable/classes/class_scenetree.html`
- `SceneMultiplayer.root_path`:
  `https://docs.godotengine.org/en/stable/classes/class_scenemultiplayer.html`
- `WebSocketMultiplayerPeer`:
  `https://docs.godotengine.org/en/stable/classes/class_websocketmultiplayerpeer.html`
- Dedicated server export/headless execution:
  `https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html`
- Command-line export/run behavior:
  `https://docs.godotengine.org/en/latest/tutorials/editor/command_line_tutorial.html`
- `CharacterBody2D` movement:
  `https://docs.godotengine.org/en/stable/tutorials/physics/using_character_body_2d.html`

## MCP And Local Validation Used

- `mcp__godot.get_project_info` confirmed the local runtime is Godot `4.6.3.stable.official.7d41c59c4`.
- Repository inspection used `rg --files` and targeted `rg` searches for multiplayer, RPC, CLI, portal, and player code.
- Godot CLI validation used:
  - `--check-only --script res://launcher/launcher.gd`
  - `--check-only --script res://client/client_main.gd`
  - `--check-only --script res://server/world/world.gd`
  - `--headless --path . --quit-after 2`

## Current Implementation Summary

The current work is still one Godot project.

Current layout:

- `launcher/`: one bootstrap scene that reads `--role`.
- `client/`: client root, player, world scenes, portals.
- `server/master/`: master server role scene and script.
- `server/chat/`: chat server role scene and script.
- `server/world/`: one shared world server role scene and script, configured by `--world`.
- `shared/`: shared route constants, CLI parsing, and RPC endpoint scripts.

Current networking shape:

- Client has sibling branches:
  - `MasterNet/MasterEndpoint`
  - `ChatNet/ChatEndpoint`
  - `WorldNet/WorldEndpoint`
- Server scenes mirror those branch-local endpoint names.
- Shared endpoint scripts are attached on both client and server sides to keep RPC declarations and signatures aligned.
- Master connection is short-lived for route lookup.
- Chat connection is intended to persist.
- World connection is intended to be replaced during transfers.

Current scene shape:

- `Player.tscn` is a `CharacterBody2D` with no gravity.
- World scenes are `world_1.tscn`, `world_2.tscn`, and `world_3.tscn`.
- World visuals and portals use `res://icon.svg` sprites with modulation.
- Labels are used only as text markers.
- Portal topology is encoded as:
  - World 1: `2,3`
  - World 2: `1`
  - World 3: `1`

## Structure Options Reviewed

### 1. Separate Role Scenes Launched Directly From CLI

- Minimalism: Medium. It avoids a launcher but requires every script/tool to know scene paths.
- Clarity: Good. Each role has an explicit scene.
- Godot-native fit: Good, since `--scene`/scene launch is supported.
- Export simplicity: Medium. Exported artifact still needs role selection or separate wrapper commands.
- CLI launch simplicity: Medium. Commands are longer and scene-path based.
- Test automation simplicity: Good but repetitive.
- Shared code cleanliness: Good.
- Future Mimic compatibility: Good, but less direct for proving one shared bootstrap.

### 2. One Bootstrap Scene That Selects Role By CLI Arguments

- Minimalism: High. One main scene, one command shape, role selected by `--role`.
- Clarity: Good if folders remain role-separated.
- Godot-native fit: Good. Godot dedicated-server docs recommend command-line arguments when client and server live in one project.
- Export simplicity: High. One project artifact can be exported and launched with different role args.
- CLI launch simplicity: High. Same binary/editor command with `--role master|chat|world|client`.
- Test automation simplicity: High. The smoke harness can start repeated processes with different args.
- Shared code cleanliness: Good.
- Future Mimic compatibility: Good. Sibling branch contexts map cleanly to future draggable networking contexts.

### 3. Separate Export Presets Or Entry Scenes Per Role

- Minimalism: Low to medium. It can create clearer named artifacts but duplicates preset/entry configuration.
- Clarity: High for final artifacts.
- Godot-native fit: Good, especially for dedicated-server features.
- Export simplicity: Medium. More presets must stay in sync.
- CLI launch simplicity: High after export, but setup is heavier.
- Test automation simplicity: Good.
- Shared code cleanliness: Good if all presets include the same project resources.
- Future Mimic compatibility: Medium. Useful later, but it is more configuration than this spike needs.

## Recommended Final MVP Structure

Keep Option 2: one bootstrap launcher scene with role-specific root scenes.

The final structure should remain:

- `launcher/Launcher.tscn`
- `client/ClientRoot.tscn`
- `server/master/MasterServer.tscn`
- `server/chat/ChatServer.tscn`
- `server/world/WorldServer.tscn`
- `shared/`
- `tools/`

The current export workflow should export a client artifact plus one standalone server artifact. The server starts master with no user args and starts worlds by creating another instance of itself with a bare world key plus launch token.

## Audit Findings

### What Looks Correct

- The project remains a single Godot project.
- Role directories are clear.
- Shared code is actually shared through endpoint scripts and config helpers.
- The implementation is still MVP-sized, not a replication framework.
- The client/server endpoint paths are intentionally mirrored:
  - `MasterNet/MasterEndpoint`
  - `ChatNet/ChatEndpoint`
  - `WorldNet/WorldEndpoint`
- Chat and world use separate `MultiplayerAPI` instances.
- `MasterNet`, `ChatNet`, and `WorldNet` are siblings, avoiding the nested custom multiplayer limitation.
- Shared RPC endpoint scripts reduce the risk of RPC signature mismatch.
- The player is top-down and uses `move_and_slide()` with no gravity.
- Portal topology matches the required graph.
- Visual sprite graphics use `res://icon.svg` with modulation.

### Risks Or Flaws Found

- `set_multiplayer()` is currently called in `_enter_tree()` and immediately asks for child node paths. Local validation showed this can fail with: `Cannot get path of node as it is not in a scene tree.`
- Moving `set_multiplayer()` to `_ready()` is acceptable for this MVP because the project does not use `MultiplayerSpawner` or `MultiplayerSynchronizer`; however, it should happen before connection/RPC setup.
- The current client reconnect helper adds `server_disconnected` signal handlers every time a world peer is replaced. That can create duplicate log callbacks and should be cleaned up while validating world transfer.
- Export presets and exported artifact smoke testing are not implemented yet.
- The automated smoke harness is not implemented yet.
- Export templates may or may not be installed locally; this must be checked when export tooling is added.
- The world server currently identifies its scene path in logs but does not need to load visual client world scenes. This is acceptable for the MVP unless later validation shows export/resource inclusion issues.

## Godot Limitations Confirmed

- Custom multiplayer branches cannot be nested.
- `SceneTree.set_multiplayer()` should be called before multiplayer-aware child nodes are ready, especially for `MultiplayerSpawner` and `MultiplayerSynchronizer`.
- RPC calls require matching node paths and node names.
- RPC declarations and annotations must match on client and server scripts.
- Server authority is the default; client-to-server RPCs require `@rpc("any_peer")`.
- `WebSocketMultiplayerPeer` URLs should include `ws://` or `wss://`.
- Godot 4 can use `--headless` for dedicated server execution without a special Godot 3-style server binary.
- If client and server roles live in the same project, official docs recommend command-line startup selection.

## Assumptions Validated

- One project can contain all roles.
- A single launcher scene with `--role` is Godot-native enough for this spike.
- Separate sibling branch multiplayer contexts are the right mechanism for persistent chat plus swappable world networking.
- Matching endpoint node names and shared endpoint scripts are the safest minimal way to satisfy RPC path/signature constraints.
- Top-down `CharacterBody2D` movement is simple and does not need platformer gravity.

## Assumptions Still Needing Implementation Validation

- The client can keep `ChatNet` connected while replacing only `WorldNet`.
- WebSocket branch peers will poll correctly after moving branch setup out of `_enter_tree()`.
- RPC dictionaries with integer world keys remain stable over Godot RPC serialization.
- The full transfer sequence passes:
  - World 1 to World 2
  - World 2 to World 1
  - World 1 to World 3
  - World 3 to World 1
- CLI export presets work on this machine.
- Exported artifacts can run the same smoke sequence.
- The smoke harness can shut down all server processes reliably.

## Decision

Keep the current structure with a small corrective refactor.

Do not switch to separate Godot projects.
Do not switch to a generic framework.
Do not add production networking abstractions.

Next implementation actions after this research note:

1. Move branch `set_multiplayer()` setup to a timing point that works locally.
2. Re-run Godot parse and headless launch checks.
3. Commit the role/client/server structure once it validates.
4. Add export and smoke tooling only after the in-editor multi-process smoke passes.
