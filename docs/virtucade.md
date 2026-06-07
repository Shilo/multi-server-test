# VirtuCade Infrastructure

This document sketches the intended server infrastructure for **VirtuCade**, a
small-scale 2D online RPG/MMORPG built from the lessons in this Godot
multi-server spike.

The goal is not to design a giant MMO platform. The goal is a small-scale
production MMO structure that can support real players, grow toward dozens of
world servers and 100-200 concurrent users, and keep the workflow reasonable
without forcing years of infrastructure work.

## High-Level Overview

VirtuCade should keep four conceptual server roles:

- **Gateway Server**: public entry point for guest sessions, register/login, and
  initial world routing.
- **Master Server**: private coordinator and database owner.
- **World Server**: authoritative gameplay runtime for one scene, map, shard, or
  instance.
- **Social Server**: chat and social presence service.

The conceptual topology is:

```text
Client -> Gateway Server  HTTP/HTTPS
Client -> World Server    Godot WebSocket multiplayer
Client -> Social Server   WebSocket or Godot WebSocket multiplayer

Gateway Server -> Master Server  internal RPC/HTTP/WebSocket
World Server   -> Master Server  internal RPC/WebSocket
Social Server  -> Master Server  internal RPC/HTTP/WebSocket
Master Server  -> Database       SQLite first, Postgres later if needed
```

The most important design rule:

```text
World servers run gameplay.
Master owns durable truth.
Gateway is the public front door.
Social owns cross-world communication.
```

For the small-scale production target, these conceptual roles do not need to be
separate deployable services. The latest same-codebase decision challenge in
[`virtucade-custom-godot-sqlite-pocketbase-decision.md`](virtucade-custom-godot-sqlite-pocketbase-decision.md)
frames collapsing Gateway, Master, and Social into one Godot Master Server as a
validation hypothesis, with SQLite embedded in that Master process:

```text
Godot Master = Gateway + Master + Social + SQLite database owner
Godot World servers = authoritative gameplay scenes
```

Earlier Nakama/PocketBase research remains useful. The current custom-first
hypothesis better matches the desire to keep the client, master, database logic,
and world servers in one Godot codebase, but it must be rejected if auth, admin,
backup, ticket, or orchestration work grows faster than expected.

Alternative compressed implementations are still possible:

```text
If using Nakama:
Nakama = Gateway + Master + Social + database/control plane
Godot = World servers

If using PocketBase:
Go/PocketBase Master Backend = Gateway + Master + Social + database
Godot = World servers

If fully custom later:
Gateway + Master + Social + World can be split into separate deployables
```

The role names remain useful even when the backend implementation is compressed
into one platform or one backend process.

## Why These Server Names

### Gateway Server

Use **Gateway Server** instead of only `Auth Server` or `Login Server` because
this role does more than authentication.

It handles:

- guest entry
- register/login
- session creation
- hub/world route lookup
- returning world addresses and entry tokens
- public HTTP requests
- basic rate limiting and abuse protection

`Auth Server` is too narrow if guests can enter before login. `Login Server` is
an older MMO term and still understandable, but it hides the routing/API role.
`Gateway Server` is the clearest general name for the public door into the
system.

### Master Server

The **Master Server** is the private control-plane server.

It should not be a gameplay server. It should not simulate maps. It should own
coordination and durable state.

It handles:

- accounts
- guest sessions
- character records
- character location
- world server registry
- world heartbeats
- transfer tokens
- database reads/writes
- save requests
- admin commands

### World Server

The **World Server** is the authoritative runtime for gameplay.

For the first production slice, each world server can host exactly one
scene/map/instance. That keeps the mental model simple:

```text
one world server process = one active playable scene
```

Later, a world server can host a small map group or multiple instances if that
becomes useful.

### Social Server

The **Social Server** starts as chat, but the name leaves room for related
cross-world social features.

It can eventually handle:

- global chat
- local/instance chat forwarding
- private messages
- guild chat
- party chat
- friends list
- online presence
- blocks/ignores
- invites
- party membership
- guild membership notifications
- mail/offline messages
- moderation logs
- chat history
- "which world is my friend in?"

Do not build all of this at once. Start with global chat and presence.

## Core Flow: Guest Starts In Hub

VirtuCade's planned flow is:

1. Player starts the client.
2. Client asks the Gateway for guest entry.
3. Gateway asks Master to create or validate a guest session.
4. Master chooses the hub world server.
5. Master issues a temporary world-entry token.
6. Gateway returns hub world address plus token.
7. Client connects to the hub World Server as a guest.
8. Client spawns in the hub as a ghost guest.
9. Client can move around the hub before registering or logging in.
10. Client cannot enter other worlds until the guest session becomes an
   authenticated account/character session.

```mermaid
sequenceDiagram
    participant C as Client
    participant G as Gateway
    participant M as Master
    participant W as Hub World

    C->>G: request guest entry
    G->>M: create guest session
    M->>M: choose hub world
    M->>M: create entry token
    M-->>G: hub address + token
    G-->>C: hub address + token
    C->>W: connect with guest token
    W->>M: validate token
    M-->>W: token valid
    W-->>C: spawn ghost guest
```

Guests should be visually distinct from logged-in characters. In the hub world,
they should appear as ghosts: visible enough to prove presence and movement, but
clearly marked as temporary/unregistered players. A guest token should only be
valid for the hub world. If a ghost guest enters a portal or requests travel to
any non-hub world, the world server should reject the transfer and show a login
or register prompt.

## Register/Login From Inside Gameplay

After the guest is already inside the hub, the player can register or login from
an in-game UI.

Recommended flow:

1. Client submits register/login to Gateway over HTTPS.
2. Gateway forwards the request to Master.
3. Master validates credentials or creates an account.
4. Master loads the selected character.
5. Master checks the character's saved world/location.
6. Master issues a world-entry token for the target world.
7. Client transfers from the guest hub to the character's real world.

```mermaid
sequenceDiagram
    participant C as Client
    participant G as Gateway
    participant M as Master
    participant H as Hub World
    participant W as Character World

    C->>G: login/register
    G->>M: authenticate
    M->>M: load character + location
    M->>M: issue target-world token
    M-->>G: target address + token
    G-->>C: transfer target + token
    C->>H: disconnect guest world
    C->>W: connect with character token
    W->>M: validate token
    M-->>W: token valid + character snapshot
    W-->>C: spawn character
```

The hub world should not own account data. It can display the login UI and
request a transfer, but the Gateway and Master should handle identity and
durable state.

## World Transfer Flow

World transfer should be explicit and token-based.

1. Client enters portal or requests travel.
2. Current World Server validates the request locally.
3. Current World Server asks Master for a transfer.
4. Master checks the destination and updates intended character location.
5. Master issues a short-lived token for the target World Server.
6. Client disconnects from current world.
7. Client connects to target world and presents token.
8. Target World Server validates token with Master.
9. Target World Server spawns the character.

```text
Client -> Current World: request travel
Current World -> Master: request transfer
Master -> Current World/Client: target address + token
Client -> Target World: connect with token
Target World -> Master: validate token
Target World -> Client: spawn
```

For the first production slice, this can be done with a simple portal and a
short-lived token.
Avoid prediction, rollback, cross-server entity handoff, and complex loading
screens until the simple version works.

## Social Server Flow

The Social Server should be independent from world travel.

The client keeps a Social connection while swapping World connections:

```text
Client -> Social Server: persistent
Client -> World Server A: active gameplay
Client swaps to World Server B
Client -> Social Server: still connected
```

The Social Server should ask Master for identity/session validation:

```text
Client -> Social: connect with session token
Social -> Master: validate session
Master -> Social: account id, character id, display name, roles
Social -> Client: connected
```

First production-slice social features:

- global chat
- sender id/display name
- online presence
- join/leave notifications

Later social features:

- private messages
- friends
- blocks
- guild chat
- party chat
- invites
- offline mail/messages
- moderation history

## Data Ownership

The safest ownership model:

| Data | Owner | Notes |
| --- | --- | --- |
| Accounts | Master | Gateway never writes accounts directly. |
| Password hashes | Master | Gateway forwards credentials over trusted internal channel. |
| Guest sessions | Master | Gateway requests them; Master owns them. |
| Character records | Master | Name, stats, saved world, saved position, inventory. |
| World registry | Master | World servers register and heartbeat. |
| Transfer tokens | Master | Short-lived and single-use if practical. |
| Runtime player position | World | Non-persistent moment-to-moment state. |
| Final saved position | Master | Updated on transfer, logout, checkpoint, or periodic save. |
| NPC/runtime entities | World | World owns simulation. |
| Chat messages | Social | Social may persist to Master DB or its own DB. |
| Friends/guilds/blocks | Social or Master | Start on Master; split to Social later if needed. |
| Audit/moderation logs | Master or Social | Depends on what produced the event. |

Simple rule:

```text
If losing it would hurt the player, Master or Social persists it.
If it only exists during active gameplay, World owns it.
```

## Live Requests, Caching, And Master Traffic

Master should own durable truth, but World and Social servers should not ask
Master for every tiny action.

Use this rule:

```text
Ask Master at trust/session/save boundaries.
Cache active session state in RAM.
Write durable changes through Master.
Keep high-frequency gameplay and chat local to World/Social.
```

### What Should Call Master

World and Social servers should call Master for:

- validating session, world-entry, and social-entry tokens;
- loading a character snapshot when a player enters a world;
- saving character location on transfer, logout, checkpoint, or timed save;
- issuing or validating world transfer tokens;
- creating, joining, leaving, or deleting guilds;
- creating or accepting friend requests;
- adding/removing blocks or ignores;
- changing account, character, role, moderation, or permission state;
- looking up another player's current world/presence when the local cache does
  not know;
- writing audit/moderation records that must survive crashes.

World and Social servers should not call Master for:

- every movement tick;
- every collision or portal overlap check;
- every local NPC update;
- every normal global chat fanout;
- every presence heartbeat if Social already owns the live connection;
- every UI refresh while the relevant data is already cached.

### Social Server Data

Social should keep active social state in RAM:

- connected clients;
- account id, character id, display name, and roles for connected users;
- online presence;
- current world id for online users if Master or World publishes it;
- joined chat channels;
- recent chat history per channel;
- active party/guild invite timers;
- rate-limit counters;
- mute/block cache for connected users.

Social should ask Master or its durable store for:

- initial identity/session validation;
- friend list load on connect;
- guild membership load on connect;
- block/ignore list load on connect;
- offline private messages/mail;
- moderation state;
- durable friend/guild/block mutations.

For the first production slice, Social can persist chat in one of two ways:

```text
Option A: Social -> Master -> database
Option B: Social owns its own SQLite database
```

Option A is simpler for one database owner. Option B is better if chat volume
grows and you want chat history isolated from account/character data. Start with
Option A unless chat history becomes noisy enough to justify a separate Social
database.

### Chat Persistence

Do not write every transient chat fanout through Master before delivering it.

Recommended chat path:

```text
Client -> Social: send message
Social -> Social RAM: validate rate limit, channel, mute/block state
Social -> clients in channel: deliver message
Social -> durable store: append message asynchronously or in small batches
```

For global chat, keep a small recent history in RAM, such as the last 50 to 200
messages per channel. Persist only what you need for moderation, reconnect
history, or audit. If chat history is not important yet, persist less and log
only moderation-relevant events.

### Friends, Guilds, And Blocks

Friends, guilds, and blocks are durable social data. They should not be
world-local.

Recommended ownership for the first production slice:

```text
Master owns durable friends/guilds/blocks.
Social caches active friends/guilds/blocks for online users.
Social asks Master to mutate durable social records.
```

Examples:

```text
Friend request:
Client -> Social -> Master: create friend request
Master -> database: save request
Master -> Social: success
Social -> recipient if online: notify
```

```text
Guild chat:
Client -> Social: send guild message
Social RAM: confirm sender is in guild
Social -> online guild members: deliver
Social -> durable store: append chat/audit if needed
```

```text
Block player:
Client -> Social -> Master: block player
Master -> database: save block
Master -> Social: success
Social RAM: update block cache immediately
```

Later, if Social becomes large enough, guild/friend/block persistence can move
into a Social database. For the first real version, keeping those records in
Master is simpler.

### World Server Data

World should keep active gameplay state in RAM:

- connected players in that scene;
- current position/velocity/input state;
- active NPCs;
- projectiles/effects;
- temporary loot;
- combat state;
- portal overlap state;
- scene-local timers.

World should ask Master for:

- token validation on join;
- character snapshot on join;
- transfer approval/token creation;
- durable character save on logout/transfer/checkpoint;
- periodic dirty character saves;
- inventory/currency/quest changes if those systems are durable.

Do not save to Master on every position change. Save on meaningful boundaries:

- entering a new world;
- logout/disconnect;
- checkpoint reached;
- inventory/currency/quest mutation;
- every 30 to 120 seconds for dirty characters;
- graceful world shutdown.

For a small MMO, a dirty-save timer is enough:

```text
World keeps character runtime state in RAM.
World marks character dirty when durable state changes.
Every N seconds, World sends dirty character snapshot to Master.
Master writes it transactionally.
```

### RAM Versus SQLite

Do not think of this as "RAM database or SQLite database." Use both:

- RAM for active sessions, tokens, connected users, hot character snapshots,
  channel membership, recent chat, presence, and runtime gameplay.
- SQLite for durable accounts, characters, saved locations, inventory, guilds,
  friends, blocks, audit logs, and chat history you care about.

It is normal for servers to cache hot data in RAM and write durable changes to a
database. It is not normal to query SQLite for every movement tick or every UI
frame. It is also risky to keep important data only in RAM without regular
transactional saves.

SQLite already has its own internal page cache, but that is not a replacement
for application-level state. The application still needs RAM objects for the
currently connected player, their current world, current channels, and live
gameplay state.

### Recommended Master Load

For the expected VirtuCade scale, Master traffic should be modest:

- Gateway calls Master on guest entry, register, login, and character selection.
- World calls Master on join, transfer, logout, dirty saves, and shutdown.
- Social calls Master on connect/session validation and durable social changes.
- Social does not call Master for every delivered chat message unless Master is
  explicitly the chat persistence owner.

This keeps Master authoritative without making it a bottleneck for every live
interaction.

## Database Recommendation

Start with SQLite if one Master process owns all durable writes.

SQLite is a good early fit because:

- one database file
- no external database server
- transactions
- indexes
- queries
- backup tooling
- WAL mode
- fewer custom save/load bugs than resource files

Use Postgres later if:

- multiple services need direct database access
- admin tools become complex
- you need better concurrent writes
- you need stronger operational tooling
- SQLite write locking becomes painful
- deployment moves to multiple machines

Do not start with resource files for account/character/social data unless the
goal is only a throwaway prototype. Resources are fine for static Godot content,
but accounts, characters, guilds, chat, and moderation logs are relational and
query-heavy.

## Transport Recommendation

Use each transport where it is strongest:

| Connection | Transport | Why |
| --- | --- | --- |
| Client -> Gateway | HTTP/HTTPS | Login, register, guest entry, request/response, rate limiting. |
| Client -> World | Godot WebSocket multiplayer | Realtime Godot gameplay and high-level replication. |
| Client -> Social | WebSocket or Godot WebSocket multiplayer | Persistent realtime chat/presence. |
| Gateway -> Master | Internal HTTP/RPC/WebSocket | Simple trusted server-to-server request flow. |
| World -> Master | Internal WebSocket/RPC | Heartbeats, token validation, transfer requests. |
| Social -> Master | Internal HTTP/RPC/WebSocket | Session validation and identity lookup. |

For this Godot codebase, using `WebSocketMultiplayerPeer` for World and Social
keeps it close to the current spike.

## Scaling Model

VirtuCade does not need a giant MMO cluster to support 100+ CCU.

Recommended scaling model:

```text
1 Gateway Server
1 Master Server
1 Social Server
N World Servers
```

Scale World Servers first:

- one hub world server
- one world server per dungeon instance
- one world server per map/scene
- one world server per busy shard

For dozens of world servers, Master needs:

- world registration
- heartbeat timeout
- player counts
- map/scene ownership
- route lookup
- transfer tokens
- graceful shutdown/drain commands

World servers should simulate only active content. A server with one inactive
scene should do almost nothing.

## Minimal Production Version

The smallest serious custom VirtuCade production shape:

```text
Gateway Server
- HTTP guest entry
- HTTP login/register
- returns hub/world address + token

Master Server
- SQLite database
- accounts
- characters
- world registry
- token issuing/validation

World Server
- Godot WebSocket multiplayer
- one scene per process
- validates token with Master
- spawns player
- portal transfer

Social Server
- WebSocket chat
- global chat
- presence
```

The current same-codebase decision challenge does not recommend building that
full custom deployment first. Validate a collapsed Gateway, Master, and Social
Godot Master process before splitting services. The validation order is:

```text
1. Custom Godot Master + embedded SQLite + Godot world-server tickets.
2. If secure auth/admin tooling becomes the bottleneck, test PocketBase as a
   sidecar or Go/PocketBase Master Backend.
3. If custom backend scope grows too large, revisit Nakama with the existing
   admission-ticket research.
4. Split Gateway, Master, and Social only after measured pressure requires it.
```

The acceptance test below remains the core product loop. The backend platform
may be a collapsed Godot Master, PocketBase-assisted backend, Nakama, or a later
custom split.

Minimal production acceptance test:

1. Start Master.
2. Start Gateway.
3. Start Social.
4. Start Hub World.
5. Start Character World.
6. Client requests guest entry.
7. Client connects to Hub World as guest.
8. Client connects to Social.
9. Client sends chat.
10. Client registers/logs in from hub.
11. Master loads/saves character.
12. Client transfers to character world.
13. Social connection remains alive.
14. Client transfers through a portal to another world.
15. Master records new character location.

## What To Avoid Early

Avoid these until the minimal production loop is stable:

- custom packet protocol
- Kubernetes
- distributed database
- multi-master persistence
- prediction
- rollback
- cross-world combat
- seamless cross-server entity streaming
- complex guild systems
- auction house
- party matchmaking
- microservice sprawl
- world servers writing directly to the account database

## Recommended Development Order

1. Keep the current Godot multi-server spike working.
2. Rename/reshape roles conceptually around Gateway, Master, World, Social.
3. Add Master-owned SQLite.
4. Add world registration and heartbeat metadata.
5. Add guest entry through Gateway.
6. Add token validation for World and Social connections.
7. Add register/login through Gateway.
8. Add character location persistence.
9. Add portal transfer with saved location update.
10. Add Social global chat and presence.
11. Add friends/blocks/private messages only after the core loop is stable.

## Final Target Shape

```mermaid
flowchart LR
    C["Client"]
    G["Gateway Server\nHTTP/HTTPS"]
    M["Master Server\nDatabase + coordination"]
    S["Social Server\nChat + presence"]
    W1["World Server\nHub"]
    W2["World Server\nDungeon"]
    W3["World Server\nTown"]
    DB["SQLite/Postgres"]

    C --> G
    C --> S
    C --> W1
    C -. transfer .-> W2
    C -. transfer .-> W3

    G --> M
    S --> M
    W1 --> M
    W2 --> M
    W3 --> M
    M --> DB
```

VirtuCade should feel like one connected world to the player, but internally it
can stay simple:

- Gateway gets players in.
- Master knows the truth.
- World servers run gameplay.
- Social keeps people connected across worlds.
