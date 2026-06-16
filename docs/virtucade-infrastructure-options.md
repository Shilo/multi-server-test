# VirtuCade Infrastructure Options, PocketBase, And Nakama Research

This document compares three possible infrastructure directions for
**VirtuCade**:

1. Full custom infrastructure: Gateway + Master/DB + Social + World servers.
2. Custom backend with PocketBase help: one Go Master Backend embedding or
   pairing with PocketBase + Godot World servers.
3. Nakama backend/control/social layer + Godot dedicated World servers.

The target is a small-scale production MMO, not a disposable prototype:

- 100-200 CCU should feel comfortable.
- Some headroom above that is useful, but 1000 CCU is not the design center.
- Dozens of world servers may exist over time.
- Godot world servers should remain authoritative for moment-to-moment gameplay.
- Prefer vertical scaling and minimal service count before horizontal scaling.
- Workflow simplicity matters because it reduces years of operational and
  integration work, not because the system is a toy.

## Recommendation Status

This page captures the earlier Nakama/PocketBase option comparison. A later
same-codebase decision spike supersedes its validation order when workflow
simplicity is weighted highest:

- [VirtuCade Custom Godot, SQLite, And PocketBase Decision](virtucade-custom-godot-sqlite-pocketbase-decision.md)

The updated working hypothesis is:

```text
Validate Custom Godot Master Server + embedded SQLite + Godot World Servers.
Do not assume it wins until auth, admin, backup, ticket, and orchestration
risks are tested.
PocketBase and Nakama remain fallback options if the custom backend grows.
```

## Earlier Recommendation

Do not build the full four-service custom infrastructure first.

Do not commit to Nakama just because it has many useful backend features.

Do not treat PocketBase as something to embed inside a Godot process.

The earlier validated next move was:

```text
Run a narrow Nakama + Godot world-server admission-ticket validation build first.
Keep Go + PocketBase Master Backend as the first custom fallback.
```

This is not a "Nakama wins" decision. It is a validation order:

1. Nakama has the larger upside because it could replace more custom
   auth/social/chat/storage work.
2. Nakama also has the larger integration-risk surface because external Godot
   persistent world servers are a bridge pattern, not the normal Nakama
   authoritative match path.
3. PocketBase is a plausible custom-backend accelerator, but only if the custom
   backend is a Go service using PocketBase as a framework or sidecar.
4. If the Nakama bridge feels contorted, build Option 2 before building a full
   Gateway + Master + Social split.

The architecture boundary should stay identical either way:

```text
Backend platform = identity, persistence, social, routing, tickets
Godot World servers = authoritative gameplay scenes
```

## Research Sources

Official PocketBase sources checked:

- https://pocketbase.io/docs/
- https://pocketbase.io/docs/go-overview/
- https://pocketbase.io/docs/authentication/
- https://pocketbase.io/docs/api-records/
- https://pocketbase.io/docs/api-realtime/
- https://pocketbase.io/docs/going-to-production/
- https://pocketbase.io/faq/

Official Nakama sources checked:

- https://heroiclabs.com/docs/nakama/getting-started/architecture/
- https://heroiclabs.com/docs/nakama/concepts/chat/
- https://heroiclabs.com/docs/nakama/concepts/friends/
- https://heroiclabs.com/docs/nakama/concepts/groups/
- https://heroiclabs.com/docs/nakama/concepts/storage/collections/
- https://heroiclabs.com/docs/nakama/concepts/status/
- https://heroiclabs.com/docs/nakama/concepts/multiplayer/relayed/
- https://heroiclabs.com/docs/nakama/concepts/multiplayer/authoritative/
- https://heroiclabs.com/docs/nakama/concepts/multiplayer/session-based/
- https://heroiclabs.com/docs/nakama/server-framework/runtime-examples/server-to-server/
- https://heroiclabs.com/docs/nakama/client-libraries/godot/

Subagent reviews were also used:

- PocketBase feasibility and Option 2 architecture.
- Nakama + external Godot dedicated server integration.
- Skeptical review challenging both options and the validation design.

## Facts That Matter

### PocketBase

PocketBase is an open-source backend with:

- embedded SQLite;
- realtime subscriptions;
- built-in auth management;
- a dashboard UI;
- a REST-ish API;
- standalone executable usage;
- Go framework usage.

PocketBase is not a Godot plugin and is not documented as something to embed
inside a Godot runtime. The practical Option 2 shape is one of these:

```text
Best custom shape:
Go Master Backend embeds PocketBase as a framework

Acceptable sidecar shape:
Custom Master Backend calls a standalone PocketBase service

Rejected validation shape:
Godot Master Server embeds PocketBase in the same process
```

PocketBase's own docs also matter for risk:

- it is pre-1.0 and not recommended for production-critical applications unless
  manual migration/changelog work is acceptable;
- it scales vertically on a single server;
- it uses SQLite and does not support replacing SQLite with Postgres out of the
  box;
- its realtime API is Server-Sent Events for subscriptions, not a game socket or
  a full social presence system.

That does not disqualify PocketBase for VirtuCade. For 100-200 CCU with
gameplay traffic direct to Godot worlds, it is plausible. It does mean Option 2
still needs custom game backend logic.

### Nakama

Nakama is a monolithic stateful game backend with:

- authentication and sessions;
- HTTP/gRPC request APIs;
- WebSocket/rUDP realtime socket APIs;
- chat;
- presence/status;
- friends;
- groups;
- storage;
- leaderboards/tournaments;
- matchmaking;
- notifications;
- server runtime modules;
- relayed multiplayer;
- Nakama-hosted authoritative matches;
- session-based dedicated server support.

Nakama still uses a database. Its architecture docs describe long-term
persistence through PostgreSQL wire-compatible databases, with CockroachDB shown
as a canonical scalable option.

Nakama open-source should be treated as single-node unless a separate high
availability strategy is built. Official architecture docs identify built-in
cluster management as an Enterprise feature.

The most important correction:

```text
Nakama authoritative matches are not Godot world servers.
```

Nakama authoritative multiplayer means writing match logic in the Nakama runtime
and running it on a Nakama node. That is not the desired VirtuCade gameplay
path. For VirtuCade, Nakama should be evaluated as the backend/control/social
plane while Godot world servers remain the simulation plane.

## Head-Of-Line Blocking

WebSocket runs over TCP. TCP can have head-of-line blocking inside a single
connection: if packet loss stalls that stream, later data on that same stream
waits behind it.

That does not mean one client's bad packet blocks every other client.

For normal server design:

```text
Client A has its own TCP/WebSocket connection.
Client B has its own TCP/WebSocket connection.
If Client A's stream stalls, Client B's stream continues.
```

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
Do not proxy Godot world gameplay through Gateway/Master/Nakama/PocketBase.
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
- More temptation to introduce Redis/message queues early.

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

Good architecture later. Too much custom infrastructure for the first
small-scale production version.

## Option 2: Go/PocketBase Master Backend + Godot World Servers

```text
Client -> Go/PocketBase Master Backend
Client -> Godot World Server

Godot World Server -> Go/PocketBase Master Backend
Master Backend -> PocketBase SQLite
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
- database ownership;
- admin tools.

World servers remain separate Godot dedicated processes.

### What PocketBase Provides

PocketBase can provide:

- auth collections and password/OAuth/OTP-style auth flows;
- stateless auth tokens;
- record collections;
- generated REST-ish record APIs;
- admin dashboard;
- SQLite persistence;
- migrations;
- API rules;
- SSE realtime subscriptions;
- Go hooks, routes, middleware, and direct database access.

### What PocketBase Does Not Remove

Option 2 still needs custom game backend logic for:

- guest hub policy;
- live session tracking;
- world-server identity;
- world registry and heartbeat expiry;
- capacity and version compatibility;
- transfer-ticket issuing and validation;
- single-use ticket consumption;
- replay prevention;
- durable character save/restore boundaries;
- chat moderation and rate limiting;
- in-memory presence;
- failure handling when a world disappears.

### Best Implementation Shape

The best Option 2 shape is:

```text
One Go backend binary using PocketBase as a framework.
```

Recommended custom routes:

```text
POST /api/virtu/worlds/register
POST /api/virtu/worlds/heartbeat
POST /api/virtu/worlds/drain
POST /api/virtu/entry/guest
POST /api/virtu/entry/login
POST /api/virtu/worlds/join
POST /api/virtu/tickets/issue
POST /api/virtu/tickets/validate
POST /api/virtu/chat/send
POST /api/virtu/characters/save
```

Recommended collections:

```text
users
profiles
characters
world_servers
world_sessions
transfer_tickets
friendships
guilds
blocks
chat_channels
chat_messages
audit_events
```

World servers should authenticate as services, not as users or superusers.
Prefer private networking plus signed HMAC headers or mTLS. Never give a world
server broad admin credentials that can mutate arbitrary account data.

### Benefits

- Small custom operational surface.
- One backend process to debug.
- Built-in auth/database/admin/REST scaffolding.
- SQLite-first workflow stays lightweight.
- Custom control over weird game-specific rules.
- Easy to understand data ownership.
- Enough for 100-200 CCU if world traffic is direct-to-world and load testing
  confirms database/write behavior.

### Costs

- You are still writing a game backend.
- PocketBase realtime is SSE record subscription, not full chat/presence.
- PocketBase auth has no traditional server sessions.
- Live presence and token revocation need custom state.
- SQLite write patterns must be protected from chat/presence spam.
- PocketBase is pre-1.0.
- Horizontal scaling is not the default shape.

### Option 2 Validation Must Prove

An Option 2 validation build is useful only if it proves the hard part:

1. Go app embeds PocketBase and boots admin UI plus migrations.
2. Client can register/login and receive a PocketBase auth token.
3. Guest entry can issue a hub ticket without creating a permanent character.
4. Godot world server registers and heartbeats through custom service auth.
5. Client requests a world assignment.
6. Backend issues a short-lived, single-use ticket.
7. Godot world server validates the ticket through the backend.
8. Expired, replayed, wrong-world, and wrong-user tickets fail.
9. Character save/restore goes through backend-owned durable state.
10. Chat or social proof works across world travel without writing every
    presence tick to SQLite.

### Verdict

Best custom fallback and possibly the final small-scale production backend if
Nakama integration is awkward. Do not embed PocketBase inside Godot; embed or
extend it from Go.

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

### What Nakama Provides

Nakama provides more game-backend substrate than PocketBase:

- proper realtime chat with room/group/direct channels and history;
- status/presence;
- friends and groups;
- storage collections;
- auth/session systems;
- official Godot client library;
- runtime RPCs and hooks;
- server-to-server RPC patterns;
- session-based dedicated-server concepts.

### What Nakama Does Not Remove

Option 3 still needs custom integration for VirtuCade:

- external Godot world registry;
- persistent-world lifecycle;
- world-server service identity;
- admission-ticket issuing and validation;
- world capacity/version/drain metadata;
- character save/reporting from world servers;
- transfer behavior across Godot world sockets;
- client behavior with both a Nakama socket and a Godot world socket.

### Correct Integration Shape

Do not use Nakama relayed multiplayer for authoritative VirtuCade gameplay.
Relayed multiplayer forwards data and does not validate gameplay.

Do not rewrite the Godot world simulation into Nakama authoritative match
runtime unless you intentionally want gameplay logic in Go/Lua/TypeScript.

The better shape is:

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
10. Client transfers to another Godot world with a new Nakama-issued ticket.
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

### Benefits

- Most non-gameplay backend features already exist.
- Official Godot 4 client exists.
- Accounts, sessions, friends, groups, chat, storage, and status are built in.
- Server runtime can enforce policies.
- Server-to-server RPC is documented.
- Session-based multiplayer docs explicitly cover headless dedicated servers.
- Lets you focus on Godot gameplay if the bridge is clean.

### Costs

- You must learn Nakama APIs, runtime, permissions, and deployment.
- Nakama's realtime socket is not Godot `MultiplayerAPI`.
- Godot `MultiplayerSpawner` and `MultiplayerSynchronizer` do not magically use
  Nakama sockets.
- Persistent worlds do not perfectly match short-lived session assumptions.
- World admission tickets must be designed.
- World server identity must be secured.
- Open-source clustering is not the same as Enterprise clustering.
- Nakama uses PostgreSQL-compatible persistence, not embedded SQLite.
- You may shape VirtuCade around Nakama concepts.

### Option 3 Validation Must Prove

A Nakama validation build is useful only if it proves the bridge, not just
auth/chat:

1. Godot client authenticates with Nakama.
2. Client restores or refreshes session.
3. Client opens a Nakama socket.
4. Client sends and receives chat or status through Nakama.
5. A Nakama RPC selects a Godot world and returns address plus ticket.
6. Godot world server validates ticket through server-to-server RPC.
7. Ticket is bound to user, session, world, expiry, and nonce.
8. Expired, replayed, wrong-world, and wrong-user tickets fail.
9. World server heartbeats or registry data are visible to Nakama runtime.
10. Client keeps Nakama social socket alive while connected to Godot world
    gameplay.
11. World server reports a durable save/result/location back to Nakama.
12. A world transfer issues and validates a second ticket.

### Nakama Validation Disqualifiers

Fail the Nakama path if:

- Godot world servers cannot validate tickets without exposing privileged Nakama
  keys to clients.
- The bridge requires rewriting world gameplay into Nakama authoritative match
  runtime.
- Persistent-world registry needs Enterprise-only clustering features at the
  target scale.
- The dual-socket model is unstable or painful in Godot.
- Character persistence becomes awkward in Nakama storage compared with a small
  custom relational backend.
- The validation build proves only easy auth/chat and skips ticket replay, world
  identity, and durable save boundaries.

### Verdict

Most promising first validation build because the upside is largest, but not
validated enough to commit. Treat Nakama as a control plane and social backend,
not as the Godot world server.

## Comparison Table

| Question | Option 1: Full custom split | Option 2: Go/PocketBase backend | Option 3: Nakama + Godot worlds |
| --- | --- | --- | --- |
| Workflow simplicity | Lowest | High | Medium after learning Nakama |
| Custom backend work | Highest | Medium | Lowest if bridge works |
| Operational complexity | High | Low | Medium |
| Accounts/auth built in | No | Yes | Yes |
| Admin UI built in | No | Yes | Yes, console |
| Chat/social built in | No | Partial | Strong |
| Database | Your choice | Embedded SQLite | PostgreSQL-compatible |
| Godot world authority | Yes | Yes | Yes, if worlds stay separate |
| Direct Godot high-level multiplayer | Yes | Yes | Yes for world only |
| Uses Godot high-level nodes in world | Yes | Yes | Yes, not through Nakama socket |
| Best for 100-200 CCU | Overbuilt | Strong | Strong if bridge works |
| Best for backend learning/control | Strong | Strong | Medium |
| Best for shipping gameplay sooner | Weak | Medium | Strong if bridge works |
| Easiest to split later | Already split | Good if modular | Depends on Nakama coupling |
| Biggest risk | Overbuilding | Custom game backend remains | Bridge/framework fit |

## Recommended Decision

Run the Nakama admission-ticket validation build first, with strict
disqualifiers.

If it passes, use Nakama as:

```text
Gateway + Master + Social + database/control plane
```

and keep Godot as:

```text
World servers
```

If it fails, build Option 2:

```text
Go Master Backend embedding PocketBase + Godot World Servers
```

Do not build Option 1 first unless Option 2 becomes too crowded or social needs
to scale independently.

## What This Means For The Existing VirtuCade Plan

The earlier VirtuCade infrastructure document describes:

```text
Gateway + Master + Social + World
```

That remains a valid conceptual model, but the small-scale production
implementation should not necessarily deploy all four as separate custom
servers.

For a minimal-service production workflow, compress the conceptual roles:

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

This keeps the mental model but lowers the workflow cost.

## Earlier Final Sequence

This was the earlier Nakama-first sequence before the custom Godot/SQLite
decision update:

```text
Phase 1: Current Godot multi-server spike
Phase 2: Nakama + Godot world server admission-ticket validation build
Phase 3A: If Nakama works, build VirtuCade backend on Nakama
Phase 3B: If Nakama does not fit, build Go/PocketBase Master Backend
Phase 4: Split Social/Gateway only if measured pressure requires it
```

The recommendation is validated enough to proceed to a production-shaped
validation build, not enough to commit to a platform permanently.
