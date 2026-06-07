# Nakama And Godot World Server Viability Research

This document answers one question for **VirtuCade**, planned as a
small-scale production MMO rather than a disposable prototype:

```text
Can Nakama replace custom Gateway/Master/Social infrastructure while Godot
headless world servers remain authoritative for gameplay?
```

## Verdict

Yes. The architecture is viable.

The recommended shape is:

```text
Client -> Nakama HTTP/gRPC API
Client -> Nakama realtime socket
Client -> Godot Hub/World Server

Godot World Server -> Nakama server-to-server RPC
Nakama -> PostgreSQL-compatible database
```

Nakama can handle:

- guest authentication;
- login/register/linking;
- sessions and refresh tokens;
- realtime socket;
- chat;
- status/presence;
- friends;
- groups/guild-like structures;
- parties;
- notifications;
- storage/database-backed character data;
- custom RPCs;
- server runtime hooks;
- world registry;
- transfer ticket issuing;
- transfer validation;
- server-to-server calls from Godot world servers.

Godot headless world servers should handle:

- live scene simulation;
- movement;
- combat;
- portals;
- NPCs;
- physics/collision;
- gameplay replication through Godot's multiplayer stack;
- moment-to-moment runtime state.

Important caveat:

```text
Nakama can replace your custom infrastructure.
It does not remove all custom backend logic.
```

The custom logic becomes Nakama runtime code instead of a separate Gateway,
Master, Social, and database service stack. That is a good trade for VirtuCade
if a production-shaped validation build confirms the Godot world-server bridge
is comfortable.

## Production Target

The target is not "prove a prototype and worry later." The target is a
small-scale MMO that can run for real players with minimal operational burden:

```text
Expected scale:
100-200 CCU, with some headroom above that

Scaling preference:
vertical scaling first, horizontal scaling only where it clearly buys safety

Workflow goal:
few moving parts, clear ownership, repeatable deployment, production monitoring

Non-negotiable:
Godot world servers remain authoritative for gameplay
```

The architecture should be production-minded from the start:

- bounded message sizes and chat rate limits;
- durable save boundaries;
- token replay prevention;
- service-to-service authentication;
- health checks and heartbeats;
- graceful drain/shutdown for world servers;
- metrics for Nakama, database, and Godot worlds;
- backup/restore plan for the Nakama database;
- clear upgrade path before scaling becomes urgent.

## Research Coverage

I used the official Heroic Labs documentation index as the coverage map. The
index listed 130 Nakama documentation pages. I cached all 130 clean Markdown
pages locally and deeply reviewed the architecture-relevant subset:

- getting started, architecture, configuration, benchmarks, console;
- authentication, sessions, sockets, user accounts;
- storage, storage permissions, storage modeling, storage search;
- chat, status, friends, groups, parties, notifications;
- multiplayer overview, relayed multiplayer, authoritative multiplayer,
  matchmaker, match listing, query syntax, session-based multiplayer;
- server framework, hooks, runtime context, server-to-server RPC, streams,
  guarding APIs, background jobs;
- Go runtime and function reference;
- Godot 4 client SDK guide;
- Godot Fish Game tutorial;
- GameLift, Edgegap, and i3D dedicated-server/fleet integrations.

Official source entry points:

- https://heroiclabs.com/docs/nakama/getting-started/
- https://heroiclabs.com/docs/nakama/getting-started/architecture/
- https://heroiclabs.com/docs/nakama/client-libraries/godot/
- https://heroiclabs.com/docs/nakama/concepts/authentication/
- https://heroiclabs.com/docs/nakama/concepts/session/
- https://heroiclabs.com/docs/nakama/concepts/sockets/
- https://heroiclabs.com/docs/nakama/concepts/storage/
- https://heroiclabs.com/docs/nakama/concepts/chat/
- https://heroiclabs.com/docs/nakama/concepts/status/
- https://heroiclabs.com/docs/nakama/concepts/friends/
- https://heroiclabs.com/docs/nakama/concepts/groups/
- https://heroiclabs.com/docs/nakama/concepts/parties/
- https://heroiclabs.com/docs/nakama/concepts/notifications/
- https://heroiclabs.com/docs/nakama/concepts/multiplayer/
- https://heroiclabs.com/docs/nakama/concepts/multiplayer/authoritative/
- https://heroiclabs.com/docs/nakama/concepts/multiplayer/relayed/
- https://heroiclabs.com/docs/nakama/concepts/multiplayer/session-based/
- https://heroiclabs.com/docs/nakama/server-framework/introduction/
- https://heroiclabs.com/docs/nakama/server-framework/runtime-examples/server-to-server/
- https://heroiclabs.com/docs/nakama/guides/server-framework/guarding-apis/
- https://heroiclabs.com/docs/nakama/guides/concepts/gamelift-integration/
- https://heroiclabs.com/docs/nakama/guides/concepts/edgegap-integration/
- https://heroiclabs.com/docs/nakama/guides/concepts/i3d-integration/

## Architecture Fit

Nakama's architecture docs describe it as a monolithic stateful server with
multiple subsystems. It exposes realtime and request APIs, keeps hot realtime
state in memory, and uses a database for long-term persistence.

That maps cleanly to VirtuCade:

| VirtuCade role | Nakama mapping |
| --- | --- |
| Gateway | Nakama HTTP/gRPC APIs plus custom RPCs |
| Master | Nakama runtime code, storage, sessions, world registry |
| Social | Nakama chat, status, friends, groups, parties, notifications |
| Database | Nakama's PostgreSQL-compatible database |
| World | Godot headless servers, not Nakama matches |

The public client should maintain two connections:

```text
Nakama socket:
auth/session identity, chat, status, social, notifications, backend RPCs

Godot world socket:
gameplay movement, spawning, combat, portals, scene replication
```

This is not a hack. The Nakama docs explicitly separate request APIs and socket
APIs, and the session-based multiplayer docs discuss Nakama coordinating
headless dedicated server instances. The difference is that VirtuCade's world
servers are persistent or semi-persistent MMO-style worlds, not short match
instances, so the registry and ticket flow should be custom Nakama runtime code.

## What Not To Do

Do not use Nakama relayed multiplayer for VirtuCade gameplay.

Relayed multiplayer forwards client data between players. Nakama keeps only the
match id and presences, does not inspect the payload, and does not validate
gameplay. That is not authoritative enough.

Do not use Nakama authoritative matches as the Godot world server unless you are
willing to rewrite world gameplay in Nakama runtime code.

Nakama authoritative multiplayer means custom match handlers running inside
Nakama with a fixed tick loop. That is useful for many games, but VirtuCade's
goal is normal Godot scene gameplay on Godot headless servers.

The correct shape is:

```text
Nakama = backend/control/social/database
Godot = authoritative world simulation
```

## Guest Hub Flow

Nakama requires users to authenticate before using server features. For
VirtuCade, a "guest" should therefore still be a Nakama user/session, but marked
as guest-level access.

Best guest identity options:

1. Device authentication with `create=true`.
2. Custom authentication with a generated guest id.

Recommended starting point:

```text
Use device auth for frictionless guest entry.
Set session variables or storage/user metadata indicating guest access.
Link email/social later if the guest upgrades into a real account.
```

Initial client flow:

```text
1. Client starts.
2. Client creates Nakama client object.
3. Client authenticates with device/custom auth as guest.
4. Client opens Nakama socket.
5. Client joins allowed guest chat channels.
6. Client calls Nakama RPC: request_hub_entry.
7. Nakama chooses hub world.
8. Nakama issues a short-lived hub ticket.
9. Client connects to Godot Hub World with ticket.
10. Hub World validates ticket via Nakama server-to-server RPC.
11. Hub World spawns the guest as a ghost.
```

Guest constraints:

- Guest can enter only the hub world.
- Guest can chat only in allowed guest/hub/global channels.
- Guest can move and interact with hub-only objects.
- Guest cannot receive a non-hub transfer ticket.
- Guest cannot save durable character progression.
- Guest cannot enter portals to other worlds.

The enforcement must happen in two places:

```text
Nakama RPC refuses to issue non-hub tickets for guest users.
Godot world server refuses non-hub entry unless the ticket says authenticated.
```

## Login While Already In Hub

There are two clean upgrade paths.

### Path A: Link Credentials To Guest

Use this when the guest is becoming a new account:

```text
1. Guest is already in hub with device/custom auth.
2. Player registers email/social credentials.
3. Client links the new auth method to the current Nakama user.
4. Nakama marks the user as non-guest and creates/loads character data.
5. Client requests a character-world ticket.
6. Hub world transfers client to the target world.
```

Benefit: the same Nakama user id persists.

### Path B: Switch To Existing Account

Use this when the guest logs into an existing account:

```text
1. Guest is already in hub.
2. Player logs into existing email/social account.
3. Client receives a new Nakama session for that account.
4. Client reconnects or refreshes Nakama socket with the real session.
5. Client requests a character-world ticket.
6. Hub world disconnects/replaces the guest identity.
7. Client connects to target world with the authenticated ticket.
```

Benefit: existing account ownership remains clean.

For the first production slice, Path B can require reconnecting the world
connection after login. Avoid trying to hot-swap a Godot multiplayer peer's
identity mid-session until the simpler reconnect flow is reliable.

## World Transfer Flow

The portal/transfer flow should be Nakama-issued and Godot-validated:

```text
1. Client enters portal in Godot World A.
2. World A validates local gameplay condition.
3. World A asks Nakama server-to-server RPC for transfer approval, or tells the
   client to request transfer through a Nakama RPC.
4. Nakama checks user/session/auth level, destination rules, and capacity.
5. Nakama writes intended location or pending transfer state.
6. Nakama issues short-lived transfer ticket for World B.
7. Client disconnects from World A.
8. Client connects to World B with ticket.
9. World B validates ticket through Nakama server-to-server RPC.
10. World B consumes ticket and spawns the player.
11. World B reports final join/save result back to Nakama.
```

Ticket fields should include:

```text
ticket_id
user_id
session_id or session hash
auth_level: guest | account | character
character_id if authenticated
source_world_id
target_world_id
target_spawn_id
expires_at
nonce
consumed_at
issued_reason: hub_entry | portal | reconnect | admin
```

Validation rules:

- wrong world fails;
- expired ticket fails;
- replayed ticket fails;
- wrong user/session fails;
- guest ticket to non-hub world fails;
- ticket from unknown or drained world fails;
- version-incompatible world fails.

## World Registry And Orchestration

Nakama can handle world registry, but this is custom runtime logic.

The official session-based multiplayer docs provide a `FleetManager` model with
`List`, `Join`, `Create`, `Get`, and `Delete` concepts for headless dedicated
servers. Official/linked integrations exist for GameLift, Edgegap, and i3D.
Those integrations are mostly oriented around on-demand game sessions with a
beginning and end.

For VirtuCade's persistent hub/worlds, the simpler production path is:

```text
Custom Nakama runtime world registry in storage + in-memory cache.
Godot world servers self-register and heartbeat to Nakama.
Nakama RPCs choose worlds from that registry.
```

World registry fields:

```text
world_id
world_type: hub | town | dungeon | instance
map_id
host
port
protocol
current_players
max_players
version
region
status: starting | ready | draining | offline
last_heartbeat_at
metadata
```

World server calls:

```text
POST /v2/rpc/world_register?http_key=...
POST /v2/rpc/world_heartbeat?http_key=...
POST /v2/rpc/world_drain?http_key=...
POST /v2/rpc/world_validate_ticket?http_key=...
POST /v2/rpc/world_report_save?http_key=...
POST /v2/rpc/world_report_disconnect?http_key=...
```

Client calls:

```text
rpc(request_hub_entry)
rpc(request_world_transfer)
rpc(request_reconnect_ticket)
rpc(select_character)
```

If VirtuCade later uses Edgegap, GameLift, i3D, or similar hosting, revisit the
FleetManager interface. For a 100-200 CCU production target with mostly
vertical scaling, a custom registry is probably less workflow burden than full
fleet orchestration.

## Server-To-Server Security

Nakama's server-to-server RPC docs say calls made without a user id in the
runtime context can be treated as server calls, and these RPCs can be invoked
over HTTP using the runtime HTTP key.

That is enough for local development, but not enough as the entire production
security model.

Production rules:

- never expose Nakama `runtime.http_key` to clients;
- never put server-to-server credentials in exported client builds;
- call server RPCs only from Godot headless world servers;
- prefer private networking between world servers and Nakama;
- add a world-server shared secret or HMAC signature per server;
- rotate world-server credentials;
- have Nakama verify `world_id` and server credential match;
- log invalid validation attempts;
- rate-limit world validation endpoints.

The `runtime.http_key` proves "not a normal authenticated client." It does not
prove which world server called unless you add that proof.

## Data Ownership

Nakama should own durable data:

| Data | Recommended Nakama location |
| --- | --- |
| User identity | Nakama users/auth |
| Guest/account flag | session variables and/or storage/user metadata |
| Character records | storage objects, server-write only |
| Character location | storage object, server-write only |
| Inventory/progression | storage objects, server-write only |
| Wallet/currency | Nakama wallet/server runtime |
| Friends | Nakama friends |
| Guilds/clans | Nakama groups |
| Global/hub chat | Nakama room chat |
| Guild chat | Nakama group chat |
| Direct messages | Nakama direct chat |
| Notifications | Nakama notifications |
| World registry | custom storage/runtime state |
| Transfer tickets | custom storage/runtime state |

Godot worlds should own live runtime state only:

- current positions;
- inputs;
- local combat;
- NPC runtime state;
- temporary drops;
- scene timers;
- portal overlap.

Worlds should report durable changes back to Nakama at boundaries:

- validated join;
- transfer;
- logout/disconnect;
- checkpoint;
- inventory/currency/quest mutation;
- timed dirty save;
- graceful shutdown.

## Chat And Social

Nakama is a strong fit for VirtuCade social features.

Useful built-ins:

- room chat for global/hub/town channels;
- group chat for guilds;
- direct chat for private messages;
- persisted message history unless disabled;
- channel presence;
- status/presence with JSON status payloads;
- friends and blocks;
- groups with roles;
- parties for temporary groups;
- notifications for transfer readiness, invites, moderation, and async events.

Guest chat is possible because guests are still Nakama-authenticated users.
Use runtime hooks to restrict where guests can chat and what APIs they can call.

Recommended guest chat rules:

- allow guest hub room;
- optionally allow limited global chat;
- block direct messages from guests;
- block group/guild creation from guests;
- rate-limit guest messages aggressively;
- use chat hooks for filtering/moderation;
- disconnect or shadow-ban abusive users through server runtime if needed.

## Godot Client SDK Fit

The official Godot 4 client guide covers the pieces VirtuCade needs:

- create a Nakama client;
- authenticate with device/custom/email/social;
- restore and refresh sessions;
- create and connect a Nakama socket;
- call RPCs over HTTP or socket;
- read/write storage;
- use friends/groups/status/chat;
- use matchmaker and matches.

For VirtuCade, do not use the Godot SDK's Nakama multiplayer match bridge as
the main gameplay transport. That bridge maps Nakama relayed/authoritative
matches into a Godot-friendly shape for match gameplay. VirtuCade wants direct
connections to Godot headless world servers.

Use the Godot SDK for:

```text
auth, session refresh, Nakama socket, chat, status, friends, groups, RPCs
```

Use the existing Godot multiplayer approach for:

```text
world server connection, player spawning, movement, portals, gameplay sync
```

## Implementation Shape

Recommended production runtime modules inside Nakama:

```text
guest_access.ts/go/lua
world_registry.ts/go/lua
transfer_tickets.ts/go/lua
character_storage.ts/go/lua
chat_policy.ts/go/lua
moderation.ts/go/lua
```

Recommended RPCs:

```text
request_hub_entry             client -> Nakama
select_character              client -> Nakama
request_world_transfer        client/world -> Nakama
request_reconnect_ticket      client -> Nakama
world_register                world -> Nakama
world_heartbeat               world -> Nakama
world_validate_ticket         world -> Nakama
world_consume_ticket          world -> Nakama
world_report_player_save      world -> Nakama
world_report_player_disconnect world -> Nakama
```

Recommended hooks:

```text
BeforeAuthenticateDevice/Custom:
  initialize guest metadata/session variables.

AfterAuthenticateDevice/Custom:
  ensure profile/guest records exist.

BeforeChannelMessageSend:
  rate-limit and filter guest chat.

BeforeChannelJoin:
  prevent guests from joining restricted channels.

BeforeWriteStorageObjects:
  block clients from writing authoritative character/inventory records.

BeforeAddFriends/CreateGroup/etc:
  block or limit guest social actions.
```

## Viability Score

| Area | Score | Notes |
| --- | --- | --- |
| Auth and guest entry | Strong | Device/custom auth gives instant guest sessions. |
| Login/register | Strong | Email/social/custom auth and linking are built in. |
| Chat/social | Strong | Chat, status, friends, groups, parties, notifications fit well. |
| Database/persistence | Good | Storage is JSON/document oriented; server-write rules are needed. |
| Godot SDK | Strong | Official Godot 4 SDK covers auth, socket, RPC, chat/social/storage. |
| World orchestration | Viable but custom | Fleet docs exist, but persistent worlds need custom registry. |
| Transfer tickets | Viable but custom | Implement as runtime RPC/storage logic. |
| Gameplay world simulation | Strong if kept in Godot | Do not use Nakama relayed gameplay for this. |
| Operational simplicity | Medium | Nakama plus database plus Godot worlds, fewer custom services. |
| Open-source scaling | Medium | Single-node OSS may be fine for 100-200 CCU if measured; clustering is Enterprise. |

## Biggest Risks

1. **Assuming Nakama is zero backend work.**
   It is not. You still write runtime RPCs, hooks, registry, ticketing, and
   persistence rules.

2. **Using the wrong multiplayer model.**
   Relayed multiplayer is not authoritative. Authoritative matches run gameplay
   inside Nakama. VirtuCade should use neither for core world simulation.

3. **Persistent worlds vs session-based docs.**
   Nakama's dedicated-server docs are more match/session oriented. Persistent
   hub/town worlds need a custom registry.

4. **Server-to-server trust.**
   The runtime HTTP key is sensitive. Add world identity checks and keep calls
   private.

5. **Data model mismatch.**
   Nakama storage is JSON/object based. Character data can work there, but model
   it carefully and keep authoritative writes server-side.

6. **Guest upgrade edge cases.**
   Decide early whether registering links credentials to the guest user or
   switches to an existing account session.

## Spike Acceptance Test

The Nakama + Godot world-server validation build should pass this end-to-end:

1. Start Nakama and database.
2. Start Godot Hub World.
3. Hub World registers with Nakama through server-to-server RPC.
4. Client starts and authenticates as guest through Nakama.
5. Client opens Nakama socket.
6. Client joins guest/hub chat.
7. Client requests hub entry through Nakama RPC.
8. Nakama returns hub address and hub-only ticket.
9. Client connects to Hub World with ticket.
10. Hub World validates ticket through Nakama.
11. Client spawns as ghost guest.
12. Guest can chat and move in hub.
13. Guest attempts non-hub portal and is rejected.
14. Client registers or logs in.
15. Nakama marks session/user as authenticated or switches to real account.
16. Client requests non-hub transfer.
17. Nakama issues non-hub ticket.
18. Client connects to target Godot World.
19. Target World validates and consumes ticket.
20. Target World reports save/location back to Nakama.
21. Nakama chat/social socket remains alive across the world transfer.
22. Expired, replayed, wrong-world, and guest-to-non-hub tickets fail.

If this passes cleanly under load and failure testing, Nakama is viable as the
VirtuCade backend platform.

## Final Recommendation

Proceed with:

```text
Nakama + Godot world servers
```

Use Nakama for backend/control/social/database responsibilities. Use Godot
headless servers for all gameplay simulation.

The first implementation should not try to use Nakama relayed multiplayer or
Nakama authoritative matches for the world. It should build the bridge:

```text
Nakama auth/session/socket/chat/social/RPC/storage
+
custom Nakama world registry and ticket runtime
+
direct Godot world server gameplay connection
```

This is meaningfully less custom infrastructure than building Gateway + Master +
Social yourself, while still preserving the thing that matters most: gameplay
stays in Godot.

## Production Readiness Checklist

Before treating this as production-ready for a small MMO, validate:

1. 100-200 simulated CCU with realistic chat, status, world joins, and
   transfers.
2. p95/p99 latency for auth, RPC ticket issue, ticket validation, chat send, and
   world join.
3. Bandwidth per client for Nakama socket traffic and Godot world traffic.
4. Database write rate during dirty saves, chat persistence, and transfers.
5. World server crash handling, stale heartbeat cleanup, and reconnect tickets.
6. Nakama restart behavior and client/session recovery.
7. Database backup and restore rehearsal.
8. Graceful drain for a world server before deploy/shutdown.
9. Abuse controls for guest chat and repeated guest creation.
10. Monitoring dashboards and alerts for Nakama, database, and Godot worlds.
