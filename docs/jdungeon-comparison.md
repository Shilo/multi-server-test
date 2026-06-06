# JDungeon Comparison Research

This note compares this project, `multi-server-test`, against
[jonathaneeckhout/jdungeon](https://github.com/jonathaneeckhout/jdungeon).

JDungeon is relevant prior art because it is also a single Godot project with
client, gateway, and game-server roles, WebSocket multiplayer, server-authority
movement, login/account flow, world/server routing, and deploy tooling. It is
closer to an actual online game than this spike, but it is also far larger and
less minimal.

For the three-way comparison between this project, Godot Tiny MMO, and JDungeon,
see [Godot Multiplayer Project Comparison Matrix](godot-multiplayer-project-comparison.md).

## Executive Summary

JDungeon is an open-source Godot .NET MORPG project. The inspected checkout uses
Godot 4.2/.NET, GDScript plus C#, a single `Main.tscn` entry scene, a selectable
client/gateway/server runtime mode, multiple `WebSocketMultiplayerPeer`
connections, a gateway for routing clients to game servers, account creation and
login, JSON or Postgres persistence, server-authority movement, custom packed
network messages, and Docker/GitHub Actions deployment.

The architecture is much closer to a real online RPG than this project. It has
gameplay systems, UI, assets, enemies, NPCs, equipment, chat, interest/view
synchronization, interpolation, prediction, lag-compensation work, and CI.

For this MVP, JDungeon should be treated as research and not as a direct
implementation target. The useful lessons are:

- A gateway can serve both game-server registration and client routing.
- A single exported Godot build can select role by startup argument.
- Each connection node can own its own branch-local `MultiplayerAPI`.
- Login to gateway can produce a short-lived cookie for game-server auth.
- Componentized sync can keep networking responsibilities close to gameplay
  objects, but it also creates a lot of surface area.
- Docker and CI are useful later, but they would overbuild this spike.

## Source Material Reviewed

Local source reviewed:

- JDungeon checkout: `C:\Programming_Files\Godot\jdungeon`
- Observed commit: `d941345f`
- Main scene: `scenes/main/Main.tscn`
- Main script: `scenes/main/Main.gd`
- Project settings: `project.godot`
- Networking docs: `documentation/networkingsync.md`
- Skill docs: `documentation/skills.md`
- Export presets: `export_presets.cfg`
- Deploy scripts: `tools/deploy/*`
- Docker files: `Dockerfile`, `docker/*`
- GitHub Actions: `.github/workflows/*`

Public sources checked:

- [GitHub repository](https://github.com/jonathaneeckhout/jdungeon)
- [itch.io page](https://jonathaneeckhout.itch.io/jdungeon)
- [Reddit web-port announcement](https://www.reddit.com/r/godot/comments/1alej2j/ported_jdungeon_godot_based_morpg_to_itch/)
- README-linked [Discord](https://discord.gg/KGwTyXumdv)
- README-linked [YouTube channel](https://www.youtube.com/channel/UCE6uLslDSAiTxxZ8BI9UYgA)

## Documentation Freshness Warning

JDungeon has some stale or transitional documentation and code.

The `documentation/networkingsync.md` file describes a `SyncRPC` node in a `G`
singleton and dictionary-style `to_json()` / `from_json()` sync. The current
main scene instead uses `NetworkMessageHandler` plus many per-system RPC
components under `Connections/ServerClient/NetworkMessageHandler`.

The source also contains older ENet/DTLS code under `todo/`, while the active
main path uses `WebSocketMultiplayerPeer`.

Portal assets and a `Portal.gd` script exist, but the transfer logic in
`scenes/terrain/portal/Portal.gd` is currently commented out. The active scene
registry in `scripts/singletons/jdungeon.gd` only registers `BaseCamp`; other
maps are present under `todo/maps`.

The Postgres backend is also worth treating carefully. A C# backend exists and
the project has SQL migrations, but the inspected `Database.gd` loader path
appears stale relative to the current file layout. That means the Postgres code
is strong architectural evidence, but it should not be assumed to run without a
small integration fix in the inspected checkout.

So the correct read is: JDungeon has a gateway/server-transfer design and live
networking architecture, but the inspected checkout does not prove a polished
multi-world portal-transfer flow in the same direct way this spike does.

## Project Shape

JDungeon is a single Godot .NET project:

- `project.godot` uses `run/main_scene="res://scenes/main/Main.tscn"`.
- `config/features` include Godot `4.2`.
- `Jdungeon.csproj` targets `Godot.NET.Sdk/4.2.1` and `net6.0`.
- GDScript is the dominant language, with C# used for Postgres and
  lag-compensation pieces.
- The README says to use the Godot .NET editor.

The repo is much larger than this spike:

- `249` GDScript files.
- `168` scene files.
- `2` C# files.
- about `100` `@rpc` annotations.
- Docker, deployment scripts, export presets, and GitHub Actions.

## Runtime Roles

JDungeon uses one main scene with three runtime modes:

- Gateway.
- Server.
- Client.

In development mode, the player chooses the role from UI buttons:

- `1 - Run as Gateway`
- `2 - Run as Server`
- `3 - Run as Client`

In deployment mode, `Main.gd` checks command-line args:

- `--gateway`
- `--server`
- otherwise client

This is similar to this project's one-launcher-scene approach, but JDungeon puts
all role nodes in the main scene and frees the unused branches at startup.

This project instead keeps separate role scenes:

- `server/master/MasterServer.tscn`
- `server/chat/ChatServer.tscn`
- `server/world/WorldServer.tscn`
- `client/ClientRoot.tscn`

Both approaches are valid. JDungeon's approach is convenient for one shared
scene and shared export. This project's approach is simpler to inspect because
each role has its own root scene.

## Connection Topology

JDungeon's `Main.tscn` has three key `WebsocketMultiplayerConnection` nodes:

- `Connections/GatewayServer`
- `Connections/GatewayClient`
- `Connections/ServerClient`

The names are easy to misread, so the purpose matters:

- `GatewayServer`: in gateway mode, this is a WebSocket server for game servers.
- `GatewayClient`: in gateway mode, this is a WebSocket server for clients.
- `ServerClient`: in server mode, this is the game server's WebSocket server for clients.

The same connection node type can run as server or client depending on role.
Each connection creates its own `MultiplayerAPI` and assigns it to its own scene
branch:

```gdscript
multiplayer_api = MultiplayerAPI.create_default_interface()
get_tree().set_multiplayer(multiplayer_api, get_path())
multiplayer_api.object_configuration_add(null, get_path())
```

That is directly relevant to this spike. JDungeon also validates the idea that
separate scene branches can own separate native multiplayer contexts.

## Gateway Flow

The gateway has two sockets:

1. A game-server-facing socket on the configured gateway-server port.
2. A client-facing socket on the configured gateway-client port.

Game servers connect to the gateway and register themselves through
`ServerFSMRPC.register_server(server_name, address, portals_info)`.

Clients connect to the gateway for login and routing through
`ClientFSMGatewayRPC`.

The gateway:

- authenticates user credentials against the database
- receives server registrations
- selects the starter server, currently `BaseCamp`
- creates a UUID cookie
- sends that cookie to the target game server
- returns server name, address, and cookie to the client

This is conceptually similar to Godot Tiny MMO's gateway/master/world token
handoff, but JDungeon combines more of the routing behavior inside the gateway.

This project has no gateway. The client asks the master directly for routes
because auth and public HTTP/API routing are out of scope.

## Client Flow

JDungeon's client state machine is in `components/connection/ClientFSM/ClientFSM.gd`.

The flow is:

1. Initialize a gateway client connection.
2. Initialize a game-server client connection.
3. Connect to the gateway.
4. Show login or account creation UI.
5. Authenticate with username/password.
6. Ask the gateway for server info.
7. Disconnect from the gateway.
8. Connect to the chosen game server.
9. Authenticate to the game server with username and cookie.
10. Instantiate the returned map scene.
11. Ask the game server to load the player.
12. Add the local player to the map.

Important difference from this project:

- JDungeon disconnects the gateway after routing.
- This project keeps chat connected while replacing only the active world peer.

So JDungeon is good prior art for temporary gateway routing. It does not directly
prove persistent cross-world chat.

## Server Flow

JDungeon's server state machine is in `components/connection/ServerFSM/ServerFSM.gd`.

The flow is:

1. Initialize a client connection to the gateway.
2. Initialize a WebSocket server for player clients.
3. Register scenes through the `J` singleton.
4. Instantiate `BaseCamp`.
5. Connect to the gateway.
6. Register the server name, address, and portal info.
7. Start accepting game clients.

Current source hardcodes:

```gdscript
%ServerFsm.map_name = "BaseCamp"
```

That keeps the active source path focused on one game server/map. It is not the
same as this project's three concurrently running world servers.

## Auth And Persistence

JDungeon has account creation and login.

The active database component supports two backends:

- JSON file backend.
- Postgres backend.

The development config uses JSON:

```text
database_backend = JSON
json_backend_file = res://data/users.json
```

The JSON backend stores passwords directly as plain text in the JSON file. The
itch page also warns users to use a bogus password because passwords are not yet
safely stored.

The C# Postgres backend uses:

- `Npgsql`
- `BCrypt.Net-Next`
- a `users` table with `username`, `password`, and `data json`

Persistent player data is handled by
`PersistentPlayerDataComponent.gd`, which stores game-facing state such as:

- current server/map name
- position
- stats
- inventory
- equipment

It writes periodically and when the player leaves the tree. That is a useful
future-MMO pattern, but it couples persistence to the game entity model and is
well beyond this spike.

This is an important distinction:

- JDungeon has real auth flow.
- Its JSON/dev backend is intentionally unsafe.
- Its Postgres direction is more production-shaped because it hashes passwords,
  but the inspected loader path should be fixed before treating it as verified.

For this MVP, all auth and persistence remains out of scope.

## Synchronization Model

JDungeon does not use Godot's `MultiplayerSpawner` or
`MultiplayerSynchronizer` in the inspected active path.

Instead it uses a custom component sync model:

- `NetworkMessageHandler` batches messages into `PackedByteArray`.
- The `Seriously` addon packs and unpacks message arrays.
- Each sync RPC component owns a numeric `message_identifier`.
- The handler maps message IDs to child components.
- Component scripts handle server/client behavior based on the current
  `MultiplayerConnection` mode.

Examples:

- `PositionSynchronizerComponent`
- `PositionSynchronizerRPC`
- `PlayerSynchronizer`
- `PlayerSynchronizerRPC`
- `StatsSynchronizerComponent`
- `InventorySynchronizerComponent`
- `EquipmentSynchronizerComponent`
- `NetworkViewSynchronizerComponent`
- `ActionSynchronizerComponent`
- `ChatServerRPC`

The player movement model is server-authoritative with client prediction:

- Client sends input frames and movement direction to the server.
- Server applies input through `move_and_slide`.
- Server sends authoritative position frames back.
- Client rewinds to last server position and replays buffered inputs.

Remote entity motion uses interpolation/extrapolation:

- Server sends timestamped position data.
- Client buffers position samples.
- Client renders slightly behind server time.

This is far more advanced than this project's high-level-node MVP.

## Interest And Visibility

JDungeon has an explicit network visibility model:

- `NetworkViewSynchronizerComponent` creates a large view `Area2D` around the
  player on the server.
- It sends add/remove messages for players, enemies, NPCs, and items as they
  enter or exit view.
- `WatcherSynchronizerComponent` tracks which player entities are watching a
  target.
- `PositionSynchronizerComponent` sends position updates only to watchers.

This is one of JDungeon's most useful ideas for future MMO work. It is also well
beyond this spike. The current project should not add AOI until the base
multi-server topology is fully understood.

## Chat

JDungeon has map chat through:

- `components/player/chatcomponent/ChatComponent.gd`
- `components/player/chatcomponent/ChatServerRPC.gd`

The chat is game-server-local:

- client sends a map message to server
- server checks the sender is logged in and has a player
- server broadcasts `_receive_map_message`
- client emits `message_received`

Whisper chat is present as an enum value but not implemented in the inspected
script.

This is closer to Godot Tiny MMO than to this project. JDungeon's chat belongs
to the game server; this project intentionally runs chat as a separate server to
prove it survives world-server transfer.

## Worlds, Maps, And Portals

JDungeon's lore and docs talk about shards, worlds, portals, and gateway-driven
server transfer. The architecture supports server registration and a
`portals_info` dictionary.

However, in the inspected checkout:

- `scripts/singletons/jdungeon.gd` registers only `BaseCamp`.
- `World`, `WakeningForest`, and `ForestDungeon` live under `todo/maps`.
- `Portal.gd` transfer logic is commented out.
- `ServerFSM.gd` currently registers an empty `portals_info` dictionary.

So JDungeon is strong prior art for the gateway-mediated travel idea, but this
project is currently the clearer proof of portal-triggered world-server transfer
between multiple running world processes.

## Export, Docker, And CI

JDungeon has a much more developed deployment story than this spike:

- `export_presets.cfg` includes Linux dedicated server, Windows Desktop, and Web.
- `tools/deploy/build.sh` exports Linux and Web builds.
- Dockerfiles run the same Linux export as `--gateway --headless` and
  `--server --headless`.
- `docker/web/docker-compose.yml` runs gateway and server containers on host
  networking.
- `resources/DeploymentConfigResource.tres` points to `wss://jdungeon.org`
  endpoints and Let's Encrypt certificate paths, but still sets
  `database_backend = JSON` with `/app/users.json`.
- GitHub Actions build Linux/Windows artifacts.
- GitHub Actions run GUT unit tests.
- GitHub Actions run formatting checks.
- Another workflow builds and pushes a Docker image.

Deployment caveats from the inspected checkout:

- The checked-in deployment config should not be treated as Postgres-backed
  without fixing the backend path/config.
- `tools/deploy/build.sh` defines a `GODOT_NET` path but invokes the non-mono
  `$GODOT` variable for exports. Treat that local shell script as stale until
  tested. The GitHub Actions workflows are stronger deployment evidence because
  they use a mono Godot container.

One caveat from the inspected checkout: at least one visible GUT test appears
stale against the current `PlayerSynchronizer` signature. So JDungeon clearly
has test/CI infrastructure, but this research did not validate that every test
currently passes locally.

This is useful deployment prior art. It is intentionally out of scope for this
MVP, which only needs local CLI export, launch, and smoke testing.

## Public Test Surface

JDungeon has an [itch.io page](https://jonathaneeckhout.itch.io/jdungeon) that
says "Run game" and describes it as testing the web port. The page also says
downloads are currently unavailable.

The Reddit web-port announcement says the game was playable on itch and notes
that ENet had been replaced by WebSocket multiplayer. That post also listed
several not-yet-ported or rough features at the time: database support, skills,
classes, portals, enemy/NPC interpolation, and hit detection.

Because this research focused on source code, I did not treat the public web
page as proof that the current local checkout is fully live or production-ready.

## Comparison Against This Project

This project is a minimal architecture spike. JDungeon is an online RPG project.

This project proves:

- one shared Godot project
- five server/client processes
- separate master/chat/world contexts
- persistent chat while replacing the active world peer
- three explicit world servers
- portal travel between world servers
- high-level RPC plus `MultiplayerSpawner` and `MultiplayerSynchronizer`
- local CLI/export smoke tests

JDungeon proves or explores:

- one shared Godot .NET project
- client/gateway/server modes
- gateway-based login and routing
- game server registration
- cookie handoff from gateway to game server
- account creation
- JSON/Postgres persistence
- custom component synchronization
- client prediction and interpolation
- network visibility/interest
- Docker and CI
- real gameplay content

The biggest difference is scope. This project answers one networking research
question. JDungeon is building a game.

## Patterns Worth Borrowing Later

Worth considering after this MVP:

1. A gateway role for public login and routing.
2. A server registration flow that includes portal metadata.
3. Short-lived world-entry cookies/tokens.
4. A config resource or config file for ports, TLS, and deployment mode.
5. Explicit connection nodes that own their own `MultiplayerAPI`.
6. Network-visible areas for later interest management.
7. Client prediction and server reconciliation as a separate movement spike.
8. GitHub Actions smoke/export testing.
9. Docker only after local process orchestration is boring and stable.

## Keep Out Of Scope For This MVP

Do not add these from JDungeon to the current spike yet:

- account creation
- password storage
- Postgres
- Docker
- public TLS/WSS deployment
- client prediction
- lag compensation
- network interest management
- gameplay systems
- equipment/inventory/stats sync
- map chat integration with account state
- CI-driven artifact publishing

They are useful future research topics, but they would blur the current proof.

## Final Recommendation

Keep this project's current architecture as the minimal baseline.

JDungeon is highly valuable as a prior-art example of a Godot MORPG moving
toward a real game. Its strongest lesson for this project is the gateway:
game servers register with a gateway, clients authenticate with the gateway,
and the gateway gives clients a target game server plus a short-lived credential.

The current MVP should not adopt that yet. It should first remain a clear proof
that separate native multiplayer contexts, persistent chat, and world-server
peer replacement work end to end.
