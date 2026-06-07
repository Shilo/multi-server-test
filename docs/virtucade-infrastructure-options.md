# VirtuCade Infrastructure Options And Nakama Research

This document compares three possible infrastructure directions for
**VirtuCade**:

1. Custom full split: Gateway + Master/DB + Social + World servers.
2. Custom small split: one Master Backend + World servers.
3. Nakama backend + Godot dedicated World servers.

The target scale is modest but real:

- 100-300 CCU should feel comfortable.
- 1000 CCU would be nice, but is not the design center.
- Dozens of world servers may exist over time.
- Godot world servers should remain authoritative for moment-to-moment gameplay.
- Workflow simplicity matters almost as much as scalability.

## Current Recommendation

Do not build the full four-service custom infrastructure first.

The two best paths are:

```text
Preferred spike:
Nakama backend + Godot dedicated World servers

Fallback custom path:
Master Backend + Godot dedicated World servers
```

In other words:

1. First, spike Nakama as the backend for accounts, sessions, social, chat,
   storage, world allocation, and server-to-server admission tickets.
2. Keep Godot dedicated servers as the only authority for live world gameplay.
3. If Nakama integration feels too constraining, fall back to a custom Master
   Backend that combines gateway/auth/social/database/orchestration.
4. Avoid a custom Gateway + Master + Social split until the custom Master
   Backend is clearly too busy or too tangled.

This recommendation is based on the workload. VirtuCade's expensive part is
Godot world simulation, not login or chat. Keep the world simulation isolated
and horizontally scalable. Do not prematurely split lightweight backend duties
into several custom services.

## Research Sources

Official Nakama sources checked:

- [Architecture overview](https://heroiclabs.com/docs/nakama/getting-started/architecture/)
- [Benchmarks](https://heroiclabs.com/docs/nakama/getting-started/benchmarks/)
- [Real-time chat](https://heroiclabs.com/docs/nakama/concepts/chat/)
- [Friends](https://heroiclabs.com/docs/nakama/concepts/friends/)
- [Groups](https://heroiclabs.com/docs/nakama/concepts/groups/)
- [Storage collections](https://heroiclabs.com/docs/nakama/concepts/storage/collections/)
- [Status and presence](https://heroiclabs.com/docs/nakama/concepts/status/)
- [Client relayed multiplayer](https://heroiclabs.com/docs/nakama/concepts/multiplayer/relayed/)
- [Authoritative multiplayer](https://heroiclabs.com/docs/nakama/concepts/multiplayer/authoritative/)
- [Session-based multiplayer](https://heroiclabs.com/docs/nakama/concepts/multiplayer/session-based/)
- [Server-to-server runtime examples](https://heroiclabs.com/docs/nakama/server-framework/runtime-examples/server-to-server/)
- [Godot 4 client guide](https://heroiclabs.com/docs/nakama/client-libraries/godot/)

Subagent reviews were also used:

- One agent reviewed custom options 1 and 2.
- One agent reviewed Nakama + Godot dedicated server integration.

## Nakama Facts That Matter

Nakama is not "just one socket server." Official docs describe it as a
monolithic stateful game backend with many subsystems in one server type:

- authentication and sessions;
- HTTP/gRPC request API;
- WebSocket/rUDP realtime socket API;
- chat;
- presence/status;
- friends;
- groups/clans;
- storage;
- leaderboards/tournaments;
- matchmaking;
- notifications;
- server runtime modules;
- relayed multiplayer;
- Nakama-hosted authoritative matches;
- session-based dedicated server support.

Nakama still uses a database. It supports PostgreSQL wire-compatible databases,
with CockroachDB shown as a canonical scalable option in the architecture docs.
So Nakama is not "one server with no DB." It is:

```text
Client -> Nakama node -> PostgreSQL-compatible database
```

For production clustering, Nakama's official architecture docs identify cluster
management as an Enterprise feature. For a small project, that means the
realistic open-source starting point is:

```text
1 Nakama node
1 database
N Godot world servers
```

That is still plenty for the likely VirtuCade target if Godot world traffic does
not run through Nakama.

## Nakama Benchmark Context

Nakama's official benchmark page reports roughly:

| Workload | One node result |
| --- | --- |
| Open socket and keep it connected | about 20,277 connected users on 1 CPU / 3 GB RAM |
| New user registration | about 528 requests/sec average |
| Existing user authentication | about 531 requests/sec average |
| Simple Go runtime RPC | about 705 requests/sec average |

Important context:

- The 20k socket benchmark is mostly authentication, opening a socket, and
  keeping it open.
- Idle connected sockets are cheap compared with gameplay simulation.
- The benchmark is not proof that one server can run a Godot MMO world for
  20,000 active players.
- Nakama is a specialized Go backend; a Godot world server is a heavier game
  engine process.

The lesson is not "one process can do everything forever." The lesson is:

```text
Backend auth/social/control traffic is probably not the bottleneck for 100-300 CCU.
Godot world simulation and replication are more likely to be the bottleneck.
```

## Head-Of-Line Blocking

WebSocket runs over TCP. TCP can have head-of-line blocking inside a single
connection: if packet loss stalls that stream, later data on that same stream
waits behind it.

That does **not** mean one client's bad packet blocks every other client.

For normal server design:

```text
Client A has its own TCP/WebSocket connection.
Client B has its own TCP/WebSocket connection.
If Client A's stream stalls, Client B's stream continues.
```

So a huge chat packet or packet loss usually hurts the affected sender/receiver
connection, not the entire server by TCP head-of-line blocking.

There are still shared-load concerns:

- a large broadcast can consume server CPU and bandwidth;
- slow receivers can build per-client send queues;
- a single event loop can be blocked by bad synchronous code;
- reliable ordered delivery is a bad fit for high-rate unreliable movement;
- Godot high-level WebSocket replication may become chatty if not tuned.

Practical VirtuCade rule:

```text
Keep gameplay world traffic on the world connection.
Keep backend/social/control traffic on the backend connection.
Do not proxy Godot world gameplay through Gateway/Master/Nakama.
```

## Option 1: Full Custom Split

```text
Client -> Gateway Server
Client -> Social Server
Client -> World Server

Gateway -> Master
Social -> Master
World -> Master
Master -> Database
```

This is the most explicitly scalable custom design.

### Benefits

- Clean role boundaries.
- Gateway can be public edge only.
- Master can stay private/internal.
- Social can scale separately from world gameplay.
- Chat/presence stays independent from world travel.
- Easier to reason about later if social becomes large.

### Costs

- More deployables.
- More logs.
- More health checks.
- More failure modes.
- More inter-service API contracts.
- More local dev setup.
- More integration tests.
- More consistency problems.
- More tempting to introduce Redis/message queues early.

### When It Makes Sense

Use this if VirtuCade needs:

- multiple public gateway nodes;
- high chat/social volume;
- separate social product features;
- 500-1000+ CCU soon;
- team members dedicated to backend operations;
- multi-region routing;
- strong service ownership boundaries.

### Verdict

Good architecture later. Too much custom infrastructure for the first serious
MVP.

## Option 2: Custom Master Backend + World Servers

```text
Client -> Master Backend
Client -> World Server

World Server -> Master Backend
Master Backend -> Database
```

The Master Backend combines:

- gateway/auth;
- guest sessions;
- account register/login;
- world registry;
- world allocation;
- transfer token issuing;
- social/chat;
- friends/guilds/blocks;
- database ownership.

World servers remain separate Godot dedicated processes.

### Benefits

- Smallest custom operational surface.
- Very easy local workflow.
- One custom backend process to debug.
- One custom database owner.
- Enough for 100-300 CCU if world traffic is direct-to-world.
- Easy to split later if modules are kept clean.

### Costs

- The Master Backend has a bigger blast radius.
- Chat/social/auth/orchestration can become tangled.
- Horizontal scaling the Master later is harder.
- If chat becomes noisy, it can pollute backend logs/storage.
- Requires discipline to keep modules separated internally.

### Recommended Internal Modules

Even if this is one process, structure it as modules:

```text
AuthModule
SessionModule
GuestModule
WorldRegistryModule
WorldAllocationModule
TransferTokenModule
ChatModule
PresenceModule
FriendsModule
GuildModule
PersistenceModule
AdminModule
```

This gives future split points without deploying separate services on day one.

### Verdict

Best custom fallback if Nakama is not used. It balances MVP workflow and
scalability well for 100-300 CCU.

## Option 3: Nakama Backend + Godot World Servers

```text
Client -> Nakama HTTP/gRPC API
Client -> Nakama realtime socket
Client -> Godot World Server

Godot World Server -> Nakama server-to-server RPC
Nakama -> PostgreSQL-compatible database
```

Nakama becomes the backend for:

- auth;
- sessions/JWT;
- users;
- storage;
- friends;
- groups/guild-like structures;
- chat;
- presence/status;
- notifications;
- matchmaking/world allocation;
- custom RPCs;
- server-to-server validation;
- persistence.

Godot world servers remain authoritative for:

- movement;
- portals;
- combat;
- NPCs;
- scene state;
- gameplay replication;
- active runtime state.

### Benefits

- Most backend features already exist.
- Official Godot 4 client exists.
- Accounts, sessions, friends, groups, chat, storage, status are built in.
- Server runtime can enforce policies.
- Server-to-server RPC is documented.
- Session-based multiplayer docs explicitly cover headless dedicated servers.
- Lets you focus on Godot gameplay instead of backend plumbing.
- Great learning path for backend patterns even if later replaced.

### Costs

- You must learn Nakama's APIs, runtime, permissions, and deployment.
- Nakama's realtime socket is not Godot `MultiplayerAPI`.
- Godot `MultiplayerSpawner`/`MultiplayerSynchronizer` do not magically use
  Nakama sockets.
- Client likely maintains both a Nakama socket and a Godot world connection.
- World admission tickets must be designed.
- World server identity must be secured.
- Open-source clustering is not the same as Enterprise clustering.
- You may shape VirtuCade around Nakama concepts.

### Correct Integration Shape

Do not use Nakama relayed multiplayer for authoritative VirtuCade gameplay.
Relayed multiplayer forwards data and does not validate gameplay.

Do not rewrite the Godot world simulation into Nakama authoritative match
runtime unless you intentionally want gameplay logic in Go/Lua/TypeScript.

The better shape is Nakama session-based/dedicated-server style:

```text
1. Client logs into Nakama.
2. Client opens Nakama realtime socket for chat/presence/social.
3. Client requests hub/world entry through Nakama RPC.
4. Nakama picks or allocates a Godot World Server.
5. Nakama creates a short-lived world admission ticket.
6. Client connects directly to Godot World Server with ticket.
7. Godot World Server validates ticket via Nakama server-to-server RPC.
8. Godot World Server runs gameplay.
9. Godot World Server reports saves/results/location back to Nakama.
```

### Client Connections

The client would probably keep two active connections:

```text
Nakama socket:
chat, friends, groups, presence, notifications, backend RPCs

Godot world socket:
movement, spawning, portals, combat, active world scene
```

That is normal. It keeps gameplay traffic separate from backend/social traffic.

### Verdict

Most promising if the priority is minimum custom backend work. It deserves a
focused spike before building custom infrastructure.

## Comparison Table

| Question | Option 1: Full custom split | Option 2: Custom Master Backend | Option 3: Nakama + Godot Worlds |
| --- | --- | --- | --- |
| Workflow simplicity | Lowest | High | Medium-high after learning Nakama |
| Custom backend work | High | Medium | Lowest |
| Operational complexity | High | Low | Medium |
| Accounts/auth built in | No | No | Yes |
| Chat/social built in | No | No | Yes |
| Database built in | No | No | Yes, PostgreSQL-compatible |
| Godot world authority | Yes | Yes | Yes, if worlds stay separate |
| Direct Godot high-level multiplayer | Yes | Yes | Yes for World only |
| Uses Godot high-level nodes in world | Yes | Yes | Yes, but not through Nakama socket |
| Best for 100-300 CCU | Overbuilt | Strong | Strong |
| Best for backend learning/control | Strong | Strong | Medium |
| Best for shipping gameplay sooner | Weak | Medium | Strong |
| Easiest to split later | Already split | Good if modular | Depends on Nakama coupling |
| Biggest risk | Overbuilding | Master monolith drift | Integration and vendor/framework fit |

## Recommended Decision

For VirtuCade, the best next move is:

```text
Run a Nakama + Godot dedicated world server spike.
```

The spike should prove:

1. Client authenticates as guest in Nakama.
2. Client connects to Nakama socket for chat/presence.
3. Client requests hub entry through Nakama RPC.
4. Nakama returns a Godot world address and admission ticket.
5. Client connects to Godot world server.
6. Godot world server validates ticket with Nakama server-to-server RPC.
7. Client moves in the Godot world using normal Godot multiplayer.
8. Client sends chat through Nakama while world gameplay remains on Godot.
9. World server reports saved location/result to Nakama.
10. Client transfers to another Godot world with a new Nakama-issued ticket.

If this works cleanly, use Nakama as the backend/control/social layer.

If this feels awkward, build Option 2:

```text
Custom Master Backend + Godot World Servers
```

Do not build Option 1 first unless Option 2 becomes too crowded or Social needs
to scale independently.

## What This Means For The Existing VirtuCade Plan

The earlier VirtuCade infrastructure document describes:

```text
Gateway + Master + Social + World
```

That remains a valid long-term conceptual model, but the MVP implementation
should not necessarily deploy all four as separate custom servers.

For MVP, compress the conceptual roles:

```text
If using Nakama:
Nakama = Gateway + Master + Social + database
Godot = World servers

If custom:
Master Backend = Gateway + Master + Social + database
Godot = World servers
```

This keeps the mental model but lowers the workflow cost.

## Handling Database And RAM

In all options, the rule is the same:

```text
RAM handles live state.
Database handles durable truth.
```

Nakama does this internally with in-memory systems for realtime routing,
presence, streams, and matchmaking, plus database persistence for long-lived
data.

A custom Master Backend should copy the pattern:

- keep sessions, presence, connected users, active tickets, and recent chat in
  RAM;
- store accounts, characters, saved locations, friends, guilds, blocks, and
  important chat/moderation logs in the database;
- do not query the database for every movement tick or every chat fanout;
- write durable changes on boundaries and mutations.

## Final Recommendation

Use this sequence:

```text
Phase 1: Current Godot multi-server spike
Phase 2: Nakama + Godot world server admission-ticket spike
Phase 3A: If Nakama works, build VirtuCade backend on Nakama
Phase 3B: If Nakama does not fit, build custom Master Backend + World servers
Phase 4: Split Social/Gateway only if measured pressure requires it
```

This gives VirtuCade the best balance:

- minimal workflow now;
- real backend features quickly;
- Godot gameplay remains authoritative;
- world servers can scale horizontally;
- no premature four-service custom backend;
- clear fallback if Nakama is not a fit.
