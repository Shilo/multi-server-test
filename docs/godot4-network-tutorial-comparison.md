# Godot 4 Network Tutorial Comparison Research

This note compares this project, `multi-server-test`, against
[somethinglikegames/godot4-network-tutorial](https://github.com/somethinglikegames/godot4-network-tutorial).

The tutorial is relevant prior art because it demonstrates a small Godot 4
gateway/authentication/world/client architecture, JWT-style world-entry tokens,
branch-local `SceneMultiplayer`, and Godot high-level scene replication with
`MultiplayerSpawner` and `MultiplayerSynchronizer`.

It is not a direct template for this MVP because it uses multiple Godot projects
and ENet/DTLS instead of one shared Godot project and WebSocket multiplayer.

For the shared multi-project comparison, see
[Godot Multiplayer Project Comparison Matrix](godot-multiplayer-project-comparison.md).

## Executive Summary

Godot 4 Network Tutorial is a tutorial repository, not a full MMO framework. It
contains four separate Godot projects in one repository:

- `authentication_server`
- `gateway_server`
- `world_server`
- `game_client`

The target architecture is:

1. Client sends username/password to the gateway.
2. Gateway forwards the login request to the authentication server.
3. Authentication server validates the request and returns a short-lived JWT.
4. Gateway forwards the token back to the client.
5. Client disconnects from gateway and connects to the world server.
6. Client sends the token to the world server after connecting.
7. World server validates the token and disconnects failures.

Important caveat: in the inspected source, token validation is tutorial-grade.
Player spawning is still driven by `peer_connected`, while JWT validation
happens later through an RPC from the connected client. That demonstrates the
handoff shape, but it is not a robust pre-spawn or pre-gameplay gate.

The strongest lesson for this project is not the repo layout or transport. The
strongest lesson is the clean separation between login/control traffic and world
simulation traffic, plus the high-level-node replication pattern:

- `MultiplayerSpawner` spawns the level.
- `MultiplayerSpawner` spawns players.
- One `MultiplayerSynchronizer` sends player input from owning client to server.
- Another `MultiplayerSynchronizer` sends server-owned player state from server
  to clients.
- Visibility can be controlled per peer with `set_visibility_for`.

For this MVP, the immediate takeaway is: keep our single-project WebSocket
architecture, but preserve the idea of separate authority-specific
synchronizers and consider a future gateway/auth token spike.

## Source Material Reviewed

Local source reviewed:

- Tutorial checkout: `C:\Programming_Files\Godot\godot4-network-tutorial`
- Observed commit: `5916265`
- README: `README.md`
- Authentication server project: `authentication_server/project.godot`
- Gateway server project: `gateway_server/project.godot`
- World server project: `world_server/project.godot`
- Game client project: `game_client/project.godot`
- Main role scripts under each project's `scenes/main.gd`
- Network scripts under each project's `scenes/network`
- Level/player scenes under `world_server/scenes/levels`
- Matching level/player scenes under `game_client/scenes/levels`
- Gateway export preset: `gateway_server/export_presets.cfg`

Public sources checked:

- [Networking tutorial 1: overview](https://www.somethinglikegames.de/en/blog/2023/network-tutorial-1-overview/)
- [Networking tutorial 2: walking skeleton](https://www.somethinglikegames.de/en/blog/2023/network-tutorial-2-walking-skeleton/)
- [Networking tutorial 3: game client login](https://www.somethinglikegames.de/en/blog/2023/network-tutorial-3-login-1/)
- [Networking tutorial 5: world server login](https://www.somethinglikegames.de/en/blog/2023/network-tutorial-5-login-3/)
- [Networking tutorial 6: DTLS](https://www.somethinglikegames.de/en/blog/2023/network-tutorial-6-dtls/)
- [Scene Replication with Godot 4(.1)](https://www.somethinglikegames.de/en/blog/2023/scene-replication/)

The public overview describes the intended gateway/authentication/world flow,
and the walking-skeleton article explicitly says the tutorial uses four Godot
projects. The scene-replication article extends the tutorial direction with
`MultiplayerSpawner` and `MultiplayerSynchronizer`.

## Documentation Freshness Warning

The local checkout appears to be tutorial source rather than a polished runnable
product.

Important caveats from the inspected source:

- The role scripts preload crypto files under `res://crypto`, such as
  `authentication_server.key`, `authentication_server.crt`, `jwt_rsa.key`,
  `jwt_rsa.pem`, `gateway_server.key`, and `world_server.key`.
- The inspected checkout did not contain those `crypto` folders or key/cert
  files. The server project `.gitignore` files also ignore `crypto/`, so these
  assets are expected to be generated or supplied locally.
- The gateway project has an `export_presets.cfg`, but the authentication,
  world, and client projects do not.
- No test suite or CI workflow was found in the inspected checkout.
- The game client's gateway login script appears to send the same login RPC
  twice: once with string-based `rpc_id(...)` and once with the typed
  `s_login_request.rpc_id(...)` form.

So this repo should be treated as architecture/tutorial evidence. It is not
proof, by itself, that the inspected checkout runs end to end without generating
the missing crypto assets and reviewing the tutorial-era code paths.

## Project Shape

This is the biggest structural difference from this project.

Godot 4 Network Tutorial is one Git repository with four separate Godot
projects. Each project has its own `project.godot` and `res://` root:

| Project | Godot project name | Main scene | Renderer/features |
| --- | --- | --- | --- |
| `authentication_server` | `Authentication Server` | `res://scenes/main.tscn` | Godot `4.1`, GL Compatibility |
| `gateway_server` | `Gateway Server` | `res://scenes/main.tscn` | Godot `4.1`, GL Compatibility |
| `world_server` | `World Server` | `res://scenes/main.tscn` | Godot `4.1`, GL Compatibility |
| `game_client` | `Game Client` | `res://scenes/main.tscn` | Godot `4.1`, Forward Plus |

The public walking-skeleton article says the split was chosen for clarity and
for safety, because the game client only contains the information it needs.

That is a reasonable tutorial/production instinct, but it conflicts with this
MVP's key constraint: one shared Godot project. Our project intentionally keeps
client, master, chat, and world roles in one project to prove shared code and
role-specific launch/export from a single codebase.

## Runtime Roles

The tutorial has four roles:

- Authentication server.
- Gateway server.
- World server.
- Game client.

There is no master server role, no standalone chat server, and no multiple
world-server registry in the inspected source.

### Authentication Server

The authentication server:

- starts an `ENetMultiplayerPeer` server on port `1911`
- configures DTLS server options
- uses Godot's `auth_callback` flow
- uses a shared HMAC secret with the gateway
- checks username/password with a tutorial placeholder: `username == password`
- issues a JWT signed with an RSA private key
- returns the token to the gateway by RPC

This is a small but useful auth-service sketch. It is not production auth:
there is no account database, password hashing, refresh token, session store, or
revocation path.

The HMAC peer-auth example is also intentionally simple. The shared secret is
hardcoded in both projects and the HMAC input is the current UTC date string. It
is useful as a Godot `auth_callback` demonstration, not as a production
gateway/auth trust design.

The JWT expires after `30` seconds and contains an `acc` claim. The inspected
world server only checks signature and expiration; it does not bind the gameplay
identity to the account claim.

### Gateway Server

The gateway project has two branch-local network nodes:

- `AuthenticationServer`: client connection from gateway to authentication
  server
- `GatewayServer`: server socket that accepts game clients

`gateway_server/scenes/main.gd` assigns separate `SceneMultiplayer` instances
to both branches:

```gdscript
get_tree().set_multiplayer(SceneMultiplayer.new(),
	^"/root/Main/AuthenticationServer")
get_tree().set_multiplayer(SceneMultiplayer.new(),
	^"/root/Main/GatewayServer")
```

The gateway:

- accepts client login requests on port `1910`
- forwards credentials to the authentication server
- receives the authentication result and token
- forwards the result to the original client
- disconnects the client from the gateway after responding

This is the cleanest concept to borrow later. It keeps the authentication server
off the normal client login path and lets the gateway act as a controlled relay.
The source itself does not enforce network isolation: the authentication server
still listens on its own ENet port, so real deployment would need firewalling,
private networking, or equivalent infrastructure controls.

### World Server

The world server:

- starts an `ENetMultiplayerPeer` server on port `1909`
- configures DTLS server options
- loads an RSA public key
- receives a JWT from the client
- checks signature and expiration in a post-connect RPC
- disconnects invalid clients
- loads one level scene after startup

Because player spawning is driven by `peer_connected`, this is not a strict
pre-spawn authorization model. A production version should delay spawning and
gameplay state until token validation succeeds.

The world server does not register itself with a master, advertise a route, or
coordinate with other world servers in the inspected source. Clients type the
world address and port directly in the login UI.

### Game Client

The client:

- starts at a small login UI
- lets the user enter gateway address/port, world address/port, username, and
  password
- dynamically creates a `GatewayServer` branch and connects to the gateway
- frees the gateway branch after login
- dynamically creates a `WorldServer` branch and connects to the world server
- dynamically adds a `Level` node and `LevelSpawner`
- uses the world connection for gameplay
- prints ENet round-trip time every five seconds

This resembles JDungeon's temporary gateway flow more than this project's
persistent chat plus swappable world flow.

## Transport And Security

The tutorial uses `ENetMultiplayerPeer`, not `WebSocketMultiplayerPeer`.

It also uses:

- DTLS for ENet transport encryption
- `TLSOptions.server(...)` on servers
- `TLSOptions.client_unsafe()` in clients
- Godot multiplayer peer authentication callbacks between gateway and
  authentication server
- a shared HMAC secret between gateway and authentication server
- JWTs for world entry

This is useful auth/security research, but not a direct transport match for the
current MVP. Our project intentionally keeps native WebSocket multiplayer
research front and center, with future browser/Web relevance. It does not
currently prove a Web export or browser client.

## Branch-Local Multiplayer

The tutorial is strong evidence for branch-local multiplayer contexts.

Every role configures a `SceneMultiplayer` for the exact node branch that owns a
connection. For example:

- authentication server branch: `/root/Main/AuthenticationServer`
- gateway client-facing branch: `/root/Main/GatewayServer`
- gateway auth-facing branch: `/root/Main/AuthenticationServer`
- world server branch: `/root/Main/WorldServer`
- client gateway branch: `/root/Main/GatewayServer`
- client world branch: `/root/Main/WorldServer`

That matches this project's core lesson: separate multiplayer responsibilities
should live under separate scene-tree branches with separate APIs.

The difference is that this project uses `MultiplayerAPI.create_default_interface()`
and WebSocket peers, while the tutorial uses `SceneMultiplayer.new()` and ENet
peers.

## Scene Replication Model

The tutorial uses Godot's high-level scene replication path.

### Level Spawning

The world server's main scene contains:

- `WorldServer/Level`
- `WorldServer/LevelSpawner`

`LevelSpawner` is a `MultiplayerSpawner` configured with:

- spawn path: `../Level`
- spawn limit: `1`
- spawnable scene: `res://scenes/levels/level.tscn`

After the world server starts, `main.gd` instantiates the level scene under
`WorldServer/Level`. The matching client branch creates the same `Level` node
and a matching dynamic `LevelSpawner` before connecting to the world server.

This is a useful pattern for server-owned level replication.

### Player Spawning

The level scene contains:

- `Players`
- `PlayerSpawner`

`PlayerSpawner` is a `MultiplayerSpawner` configured to watch `../Players` and
spawn `res://scenes/levels/player.tscn`.

The server-side `level.gd`:

- adds players for existing peers
- listens for `peer_connected`
- listens for `peer_disconnected`
- instantiates `player.tscn`
- sets `character.player = id`
- randomizes spawn position
- names the node by peer ID
- adds it under `Players`

The clients have a matching level scene with the same `Players` and
`PlayerSpawner` structure, but no level script.

That matching path setup is directly relevant to our current `SpawnRoot` and
`MultiplayerSpawner` work.

### Player Synchronization

The player scene has two `MultiplayerSynchronizer` nodes:

- `ServerSynchronizer`
- `PlayerInput`

`PlayerInput`:

- extends `MultiplayerSynchronizer`
- synchronizes `direction`
- receives local input only when its multiplayer authority matches the local
  peer ID
- sends jump/color RPCs to the server with `@rpc("call_local")`

`ServerSynchronizer`:

- synchronizes server-owned player state
- has `public_visibility = false`
- includes spawn/watch properties such as `player`, `position`, `velocity`, and
  `currentColor`

The player script sets the `PlayerInput` authority based on the server-assigned
player ID:

```gdscript
@export var player := 1:
	set(id):
		player = id
		$PlayerInput.set_multiplayer_authority(id)
```

That is the cleanest high-level-node idea to keep studying. It separates
client-owned input from server-owned output instead of making one synchronizer
carry every responsibility.

## Visibility

The server-side player scene has an `Area3D`. When bodies enter or exit that
area, `player.gd` calls:

```gdscript
synchronizer.set_visibility_for(str(body.name).to_int(), true)
synchronizer.set_visibility_for(str(body.name).to_int(), false)
```

That is a tiny high-level-node interest-management sketch. It is much smaller
than JDungeon's watcher/view system, but it points in the same direction:
visibility should eventually be explicit instead of broadcasting all state to
all clients.

For this MVP, visibility filtering remains out of scope. It is worth keeping as
a later spike because it uses Godot's own `MultiplayerSynchronizer` visibility
features instead of a custom AOI packet system.

## Chat, Worlds, And Travel

The tutorial does not implement chat.

It also does not implement server-to-server world travel. The public overview
does mention that splitting a large world across multiple servers would require
server changes during zone transitions, but it explicitly treats that as a
larger topic.

The inspected source has one world server role and one level. The client can
choose the world address manually in the login screen, but there is no master
registry, dynamic route lookup, portal graph, transfer authorization, or
persistent chat connection.

This means:

- This project is the stronger proof of active world-peer replacement.
- Godot Tiny MMO and JDungeon are stronger references for gateway/world routing.
- Godot 4 Network Tutorial is the clearest small reference for JWT handoff plus
  high-level spawner/synchronizer ownership.

## Export And Testing

The inspected checkout has limited export/test automation:

- `gateway_server/export_presets.cfg` exists.
- No export presets were found for `authentication_server`, `world_server`, or
  `game_client`.
- No GitHub Actions workflows were found.
- No test files were found.
- Server projects set editor `main_run_args` to `--display-driver headless`.

This is much thinner than this project's CLI/export/smoke workflow and much
thinner than JDungeon's Docker/CI setup.

## Comparison Against This Project

This project proves:

- one shared Godot project
- WebSocket native multiplayer
- separate branch-local master/chat/world contexts
- persistent chat while replacing the active world peer
- three running world server processes
- portal-triggered world transfer
- `MultiplayerSpawner` and `MultiplayerSynchronizer` in the current world/player
  scenes
- local CLI/export smoke testing

Godot 4 Network Tutorial proves or explores:

- four-role gateway/auth/world/client architecture
- separate Godot projects per role
- ENet transport
- DTLS
- peer auth callbacks
- HMAC gateway/auth trust check
- JWT world-entry token
- temporary gateway connection followed by world connection
- branch-local `SceneMultiplayer`
- high-level level/player spawning
- input synchronizer authority assigned to the owning client
- server-owned state synchronizer
- synchronizer visibility controls

The biggest difference is research target. This project isolates multi-server
WebSocket travel in one project. The tutorial teaches Godot 4 networking
building blocks across multiple projects.

## Patterns Worth Borrowing Later

Worth considering after the current MVP stays stable:

1. Add a future gateway/auth spike.
2. Route normal client login traffic through a gateway before it reaches
   authentication.
3. Issue short-lived world-entry tokens instead of letting clients join worlds
   with no credential.
4. Keep world-entry token verification on world servers.
5. Split player replication into authority-specific synchronizers:
   client-owned input and server-owned result state.
6. Use `MultiplayerSynchronizer.set_visibility_for` in a tiny AOI spike.
7. Keep level spawning server-owned through `MultiplayerSpawner`.
8. Add explicit connection data objects for addresses/ports if config grows.

Real authentication isolation would still need deployment controls such as
firewall rules, private networking, or non-public bind addresses.

## Keep Out Of Scope For This MVP

Do not import these into the current spike yet:

- multiple Godot projects
- ENet transport
- DTLS setup
- JWT implementation
- HMAC peer-auth handshakes
- real login flow
- account database
- crypto key generation and rotation
- synchronizer visibility/AOI
- 3D movement scene
- manual world address UI

They are useful research topics, but they would blur the current WebSocket
multi-server travel proof.

## Final Recommendation

Keep this project's current one-project WebSocket architecture.

Use Godot 4 Network Tutorial as a focused reference for two future spikes:

1. Gateway/auth/token world-entry flow.
2. Cleaner high-level scene replication with separate synchronizers for input
   and server-owned state.

Do not copy its repo layout into this MVP. The four-project split is useful for
a security-oriented tutorial, but this spike's learning value depends on proving
that one shared Godot codebase can launch and export multiple roles cleanly.
