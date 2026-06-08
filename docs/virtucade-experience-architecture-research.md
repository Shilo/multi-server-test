# VirtuCade Experience Architecture Research

This is the second research iteration for the current VirtuCade direction:

```text
Client + one Godot Master Server + on-demand Godot World Servers
```

The target is not a prototype-only shape. It is a small-scale production-minded
Virtual Arcade that can plausibly run around 100-200 CCU on a single vertically
scaled Hetzner VPS, with a workflow simple enough to maintain inside one Godot
project.

The desired long-term collapse is:

```text
Godot Master Server = database owner + authentication + gateway/API + social/chat + world orchestration
Godot World Server  = one active mini-game / experience scene process
```

Worlds are disposable. The master is durable.

## Research Inputs

Local projects:

- `C:/Programming_Files/Godot/godot-tiny-mmo`
- `C:/Programming_Files/Godot/jdungeon`
- `C:/Programming_Files/Godot/godot4-network-tutorial`

Online references:

- [Roblox experiences and places](https://create.roblox.com/docs/production/publishing/publish-experiences-and-places)
- [Roblox teleport between places](https://create.roblox.com/docs/projects/teleport)
- [Roblox Data Stores](https://create.roblox.com/docs/cloud-services/data-stores)
- [Roblox data stores vs memory stores](https://create.roblox.com/docs/cloud-services/data-stores-vs-memory-stores)
- [Roblox Memory Stores](https://create.roblox.com/docs/cloud-services/memory-stores)
- [Mirror Engine mirrored multiplayer](https://mirrorengine.io/how-to/mirrored-multiplayer)
- [Mirror Engine feature positioning](https://mirrorengine.io/)
- [Mirror Engine introduction blog](https://mirrorengine.io/blog/next-gen-game-engine-ai-text-to-3d-multiplayer-entity-component-system-whats-next)

## Recommendation

Keep the current custom Godot direction:

```text
one Godot client
one persistent Godot master server
many temporary Godot world server processes
one scene per world process
one shared Godot codebase
one server executable for master and worlds
SQLite embedded in the master when persistence is added
```

Do not add a separate gateway, auth server, chat server, Nakama, PocketBase,
Redis, Docker layer, FleetManager, Kubernetes, or multi-VPS orchestration for the
current MVP.

Challenge: this only remains sane if the master is treated as separate modules
inside one process, not as one giant script. The process count can stay minimal,
but the code boundaries cannot be vague.

Recommended master modules:

```text
MasterServer
  GatewayApi          public login/register/session/route surface
  AuthService         account/session/token rules
  DatabaseService     the only durable SQLite writer
  SocialService       global chat, friends, presence
  WorldRegistry       world process state and live routes
  TicketService       one-use join/transfer tickets
  WorldOrchestrator   start/stop/heartbeat/idle shutdown
```

These do not need to be separate processes.

## The Roblox Lesson

Roblox's most useful model for VirtuCade is the distinction between an
experience and its places.

The Roblox docs describe an experience as starting with one place, then
supporting additional places for different gameplay areas. The docs compare
places to Unity scenes or Unreal maps. That maps cleanly to VirtuCade:

```text
Roblox experience -> VirtuCade as a whole
Roblox start place -> hub world
Roblox place -> Godot world scene
Roblox server instance -> Godot headless world process
Roblox teleport -> master-approved world transfer
```

The secure teleport lesson is just as important. Roblox recommends moving
teleport logic into server scripts for secure teleports, and warns that
teleport data is not appropriate for secure inventory or currency. For
VirtuCade, this means:

- Clients may request travel.
- The current world or master should authorize travel.
- Target worlds should only spawn players with master-issued one-use tickets.
- Currency, inventory, and RPG stats must be loaded from durable master-owned
  storage, not trusted from client-supplied transfer payloads.

The current spike already uses master-issued one-use world join tickets. The
future production step is to make portal authority server-side, so the client is
not the source of truth for which portal was entered.

## The Tiny MMO Lesson

Tiny MMO is the closest architectural inspiration, but it is larger than this
project should copy.

Useful evidence from Tiny MMO:

- It keeps client and multiple server roles in one Godot repository.
- It uses feature tags / role modes for local multi-instance testing.
- It has a Gateway, Master, and World architecture.
- The master README says the master lets gateways/worlds connect, returns
  available worlds, creates temporary world-entry tokens, owns account data, and
  leaves characters in world servers.
- Worlds register and heartbeat to master.
- World entry uses temporary tokens.
- World servers can host multiple map instances and unload unused instances.
- It migrated mutable player/guild/chat persistence to SQLite.

What to adopt:

- One codebase.
- Clear internal role boundaries.
- World registration and heartbeat.
- Temporary entry tickets.
- Periodic saves, final saves, and backups once persistence exists.
- Static game content as Resources.
- SQLite for mutable durable data.

What to reject for this MVP:

- A separate Gateway process.
- Per-world databases for global player/currency/inventory data.
- Account/password storage as Resource files.
- Large custom byte-packed replication.
- Admin dashboard scope.
- A broad shared MMO component framework.

Tiny MMO's movement from Resource-backed world data to SQLite is a strong
warning against using Godot Resources as the durable player database. Resources
are still excellent for static content: item definitions, mini-game manifests,
NPC templates, skill definitions, and world metadata. They are weak for mutable
concurrent account/player/chat/guild data.

## The jdungeon Lesson

JDungeon proves that one Godot project can run multiple roles, including
gateway/server/client, with a single exported codebase and command-line role
selection. It also has useful server-only persistence habits:

- Load persistent player data only on the server.
- Save periodically.
- Save on tree exit.
- Keep stats, inventory, and equipment as serializable components.

What to adopt:

- Server-only load/save discipline.
- Periodic save interval for connected players or active sessions.
- Save-on-exit as a final safety net.
- A small component-to-dictionary persistence surface.

What to reject for this MVP:

- Its full component registry/network message framework.
- Its gateway process.
- Its prediction/reconciliation stack until real gameplay requires it.
- Its portal transfer code as evidence; the relevant portal code is commented
  out and should not drive this design.

## The Godot Network Tutorial Lesson

The Godot 4 network tutorial is useful mainly as a topology teaching aid:

- It has separate network branches for gateway/master-like traffic and world
  traffic.
- It shows a token shape where a client gets a short-lived credential and
  presents it to the world server.
- It demonstrates simple spawn/despawn on peer connect/disconnect.

What to adopt:

- Separate `MasterNet` and `WorldNet` multiplayer branches.
- Short-lived world-entry credentials.
- Simple server-owned spawn/despawn.

What to reject:

- Static/manual endpoint selection.
- Separate auth/gateway/world projects.
- JWT complexity for the current MVP.
- Movement architecture beyond the current client-authority movement spike.

The current project is already closer to the intended architecture than this
tutorial because the master starts worlds on demand and issues one-use join
tickets.

## The Mirror Engine Lesson

Mirror Engine is useful philosophically, not as architecture to copy.

Its pitch is that everything is multiplayer by default, assets stream to
players, and the platform handles sync, databases, publishing, and cloud
services. That is the opposite infrastructure direction from VirtuCade's
single-VPS, one-codebase target.

What to adopt:

- Keep the creator mental model simple.
- Prefer composition for mini-game behavior.
- Make the default workflow feel like building one game, not operating a fleet.

What to reject:

- "Everything syncs automatically."
- Cloud asset streaming as a base requirement.
- Platform-scale database/publishing assumptions.
- Building a generic engine/platform before the arcade game exists.

## Experience And State Model

VirtuCade worlds are closer to Roblox places than classic MMO zones. A world may
be:

- the hub world
- a combat RPG area
- a drawing room
- a music room
- a video room
- a coding activity
- a standalone arcade mini-game
- a game with no normal player avatar

Because worlds can be heterogeneous, the shared world contract must stay small:

```text
World scene should support:
  spawn_player(peer_id)
  remove_player(peer_id)
  optional portal/travel requests
  optional session result reporting
  optional local save/load hooks
```

Do not force every world to share one RPG player, one inventory model, or one
replication framework.

Recommended state buckets:

```text
global_profile
  Durable.
  Master-owned.
  Account, session, display name, global currency, global inventory, global RPG stats.

world_session
  Ephemeral.
  World-process-owned.
  Current match state, timers, temporary items, local score, spawned entities.
  Dies when the world process shuts down.

world_player_state
  Durable only when that world needs it.
  Master-owned row keyed by account/player + world_key.
  Per-experience stats, unlocks, inventory, save file, preferences.

world_result
  Durable event submitted by the world to master.
  Idempotent by result_id or match_id.
  Used for rewards, achievements, currency grants, scoreboards.
```

This avoids the worst failure mode: every world directly mutating global player
truth in its own way.

## Database Direction

Use SQLite embedded in the master server for the first real persistence pass.

Why:

- One writer process: the master.
- No separate database service.
- Simple local testing.
- Simple Hetzner deployment.
- Fits 100-200 CCU if writes are batched and narrow.
- Easier backup story than Resource files.
- More appropriate than PocketBase if the goal is not to run a separate DB/API
  service.

Do not let world servers directly write the SQLite database for global state.
Worlds should send requests/results to master. Master serializes durable writes.

Suggested first schema direction:

```text
accounts(id, username, password_hash, created_at, updated_at)
sessions(id, account_id, token_hash, expires_at, created_at)
players(id, account_id, display_name, current_world_key, created_at, updated_at)
global_wallets(player_id, currency_key, amount)
global_inventory(player_id, item_key, quantity, data_json)
global_stats(player_id, stats_json)
world_player_state(player_id, world_key, state_json, updated_at)
world_results(result_id, player_id, world_key, result_json, created_at)
world_instances(instance_id, world_key, state, started_at, stopped_at)
```

This can start much smaller. The key is the ownership boundary, not table count.

## World Lifecycle Direction

The current lifecycle remains correct:

```text
request route/transfer
master ensures target world process exists
world registers with master
master sends one-use join ticket to world and client
client connects directly to world
world validates ticket before spawning
world heartbeats player count
master stops world after zero players and zero pending joins for idle timeout
world self-exits if it loses master
```

This is a good single-VPS model. The master is the orchestrator. Worlds should
not decide their normal idle shutdown alone, because the master has the full
view of pending transfers, live routes, and process state.

Worlds should still have self-exit fallback when they lose master, because
Godot-created processes are independent and a master crash can otherwise leave
stale world processes behind.

## Hetzner Deployment Shape

Keep deployment boring:

```text
systemd service: VirtuCade master/server executable
master process: owns SQLite and world process orchestration
world processes: child instances of same server executable
SQLite file: local disk, backed up on a schedule
reverse proxy/TLS: add later when public hosting needs it
```

For the current MVP, do not add Docker just to run Godot and SQLite. Docker can
still be useful for packaging later, but it does not solve the core gameplay
orchestration problem and it adds another workflow layer.

## Challenges To Keep In View

The simplified architecture is viable, but these are real pressure points:

- Master can become too large unless service boundaries are explicit.
- One SQLite writer is simple, but master DB code must avoid long blocking work
  during hot network paths.
- If a mini-game becomes popular, one world key may need multiple concurrent
  instances, not one process.
- Dynamic sorted ports are convenient locally but unstable if world names change.
- Server-side portal/travel authority is needed before public testing.
- Join tickets gate world entry but are not a full authenticated session model.
- Command-line launch tokens are acceptable on a private single-user VPS, but
  not a strong secret boundary on shared hosts.
- World shutdown must become graceful before worlds save durable results.

None of these require a gateway or external backend today. They require the
master to be modular and the world contract to stay intentionally small.

## MVP-Safe Next Steps

1. Keep the current `client + master + world` architecture.
2. Keep `MasterNet` and `WorldNet` separate.
3. Keep master-owned world orchestration.
4. Keep worlds DB-free for global durable state.
5. Add a master-owned SQLite `DatabaseService` in a future persistence pass.
6. Add `WorldManifest` Resources later if world metadata outgrows scene exports.
7. Add authenticated sessions before public testing.
8. Move portal authority server-side before public testing.
9. Add graceful world shutdown hooks before durable world results.
10. Consider multi-instance-per-world only after one world becomes a bottleneck.

## Verdict

The current architecture is not just an MVP shortcut. It is a reasonable
small-scale production architecture if the master is treated as the durable
control plane and the worlds are treated as temporary experience runtimes.

The strongest challenge is not "do we need Nakama/PocketBase/gateway now?" The
strongest challenge is "can the master stay clean while absorbing auth, DB,
gateway, chat, and orchestration?" The answer is yes only if those are explicit
modules behind small APIs.

For VirtuCade, the minimal stable direction is:

```text
Build a Roblox-like experience/place model in Godot.
Keep worlds lightweight and heterogeneous.
Persist durable truth through the master.
Let world processes come and go.
Avoid infrastructure until the single VPS proves insufficient.
```
