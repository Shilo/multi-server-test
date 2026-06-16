# VirtuCade Database Handling Spike

Date: 2026-06-09

This spike answers how VirtuCade should handle durable data for a small-scale
MMO/virtual arcade with one persistent Godot master server and temporary Godot
world server processes.

The target is not "prototype only." The target is a small production-minded
deployment on one VPS, roughly 100-200 CCU, with a workflow that does not create
years of backend infrastructure work.

## Recommendation

Use a master-owned `DatabaseService` with embedded SQLite first.

```text
Client
  -> MasterNet: guest session, login/register, chat, routes, transfer control
  -> WorldNet: active gameplay only

World Server
  -> Master: join validation, load snapshot request, save/result commands

Master Server
  -> DatabaseService
  -> SQLite file on local disk
```

World servers should not open the SQLite database file, should not know SQL
schema, and should not directly write account, inventory, currency, character,
or ticket rows. They should keep active gameplay state in RAM, then send
validated save/result commands to the master.

This is not because centralizing everything is always best. It is because
VirtuCade's current worlds are temporary, on-demand processes. Spreading durable
database writes into those processes makes authority, credentials, migrations,
and race handling harder before it meaningfully improves performance.

## Direct Answers

### 1. External Database Or Embedded In Master?

For the current VirtuCade shape, embedded SQLite inside the master is the best
first persistence target.

Why it fits:

- One VPS.
- One persistent master process.
- Temporary worlds.
- Low-to-moderate write volume.
- No desire to operate a separate DB service yet.
- Local-disk database file with simple backups.
- One Godot codebase and one server export can remain the default workflow.

Why it is not free:

- SQLite has many readers but one writer per database file.
- Godot-side database calls can still block if handled poorly.
- Password hashing, migrations, backups, and admin tooling are still real
  backend work.
- If secure auth needs a helper service or native addon anyway, the "pure Godot"
  advantage shrinks.

External Postgres becomes the better answer when:

- the master is no longer the only durable writer;
- multiple VPSes or multiple master/control processes appear;
- SQLite write queue latency becomes visible;
- trading, auction, moderation, audit, reporting, or web admin queries become
  central;
- you want mature DB ops and tooling more than minimum service count.

PocketBase is not just "a better SQLite." It is a small backend platform with
SQLite, auth, dashboard, REST-ish API, realtime subscriptions, and Go/JS
extension hooks. It is a valid fallback if auth/admin/REST workflow matters more
than keeping the master backend in Godot. It should be treated as a sidecar or a
Go/PocketBase backend, not something embedded inside a Godot process. Also note
that PocketBase's own docs still warn that full backwards compatibility is not
guaranteed before v1.0, so it should be adopted deliberately rather than as a
magic "production solved" checkbox.

### 2. How Do Games Usually Read And Write Data From Multiple Worlds?

There is no single universal rule, but common production patterns are:

| Pattern | How it works | VirtuCade fit |
| --- | --- | --- |
| Central backend/data service | Game/zone/world servers call a backend service, which owns transactions, auth, inventory, currency, and saves. | Best fit. The Godot master already is that backend/control plane. |
| Direct DB from world servers | Every world connects to a central SQL database and writes with strict transactions, locks, and schema discipline. | Common enough with Postgres/MySQL, but bad for this SQLite-first, temporary-world design. |
| Backend platform | Nakama, Pragma, PlayFab, or similar owns auth/storage/social APIs; game servers use server APIs. | Good if you accept another backend platform. It fights the current minimal one-codebase goal. |
| Per-world database | Each world owns local persistence. | Wrong for global accounts, inventory, currency, and cross-world characters. Only useful for truly local world history. |

The standard principle is stronger than any one topology:

```text
Live simulation state lives in memory.
Durable player truth is committed through a controlled persistence boundary.
```

Do not use the database for movement ticks, collision state, animation state, or
per-frame gameplay. Database writes should be login, register, join, transfer,
checkpoint, dirty save, logout, rewards, inventory changes, moderation, and
optional chat history.

### 3. Should Master Write To DB And Worlds Read From DB?

No. The cleaner shape is:

```text
Master reads from DB.
Master sends a snapshot to the world.
World mutates active session state in RAM.
World sends save/result commands back to Master.
Master writes to DB.
```

Worlds can "load" character data by asking master, but they should not read the
database directly.

For example:

1. Client requests route or transfer.
2. Master starts target world if needed.
3. Master creates a short-lived join ticket and records the target.
4. Master loads the player's global and per-world snapshot.
5. Master gives the world the expected ticket and player snapshot.
6. Client joins the world with the ticket.
7. World consumes the ticket, spawns the player, and owns live simulation.
8. On transfer/logout/checkpoint, world sends a save command to master.
9. Master commits a transaction and replies with an ACK.

This preserves a single durable writer while still letting the world be
authoritative for gameplay during the session.

### 4. Do We Need Database Subscribers?

Not for normal player load/save.

Use request/response and dirty-event pushes first:

- Client asks master for login/session/route.
- World asks master for join validation and snapshot.
- World sends save/result commands to master.
- Master pushes chat, route, transfer, or social updates over `MasterNet`.

Subscribers are useful only for specific problems:

- cross-world invalidation: "this character's inventory changed, refetch";
- admin/moderation actions: "kick this user" or "mute changed";
- website dashboards that want live updates;
- future multi-master or Postgres deployment.

SQLite has no network changefeed. If master owns the DB, the master itself can
publish events to connected clients/worlds after it commits a transaction.

Postgres `LISTEN`/`NOTIFY` is useful later as a change signal, but it should not
carry large player payloads. Use it as "something changed; refetch by id."

PocketBase realtime subscriptions are useful for web/admin/client record
updates, but they are not a replacement for Godot world networking or
server-authoritative gameplay.

SpacetimeDB-style subscriptions are a different architecture: the database also
becomes the realtime backend. That is powerful, but it is not a small incremental
storage layer for the current Godot master/world design.

### 5. Authentication: HTTP Or WebSocket?

For the current Godot-only workflow, WebSocket RPC over `MasterNet` is the
lowest-friction way to support guest entry, login/register UI, chat, routing, and
world transfer.

For production credentials and website integration, HTTPS should be planned as a
future transport.

Recommended transport rule:

```text
Keep AuthService transport-neutral.
Expose it over MasterNet first.
Add HTTPS later if website/account flows need it.
```

That means the internal code should be shaped as:

```text
AuthService.create_guest()
AuthService.register(username, password)
AuthService.login(username, password)
AuthService.refresh_session(token)
AuthService.logout(session_id)
```

The game client can call those over `MasterNet`. A future website or launcher can
call the same service through HTTPS.

Important challenge: Godot has client HTTP APIs, but it is not a batteries-
included public HTTP/TLS/rate-limit web server. If public HTTPS login becomes
urgent, the serious options are:

- a tiny Go/Rust/C# HTTP auth/API sidecar calling the same database;
- PocketBase for auth/admin/API;
- a reverse proxy plus a deliberately designed API process;
- Postgres plus a conventional backend if the project outgrows Godot-only.

Do not expose raw database access to a website. Website integration should call
an API layer, not SQLite or Postgres directly.

For WebSocket auth, production must use `wss://`, token validation, message
authorization, input limits, rate limits, and session expiration handling.

### 6. Best Libraries And Tutorials

Recommended first stack:

- `2shady4u/godot-sqlite` for Godot 4 SQLite access.
- Plain SQL migrations under `server/master/db/migrations/`.
- A master-owned `DatabaseService` API instead of SQL calls scattered through
  endpoint scripts.
- OWASP password-storage guidance for auth design.
- Godot Resources or a resource registry for static item/world definitions, not
  mutable account/player state.

I did not find a mature "complete MMO database solution for Godot" that should
replace this architecture. The practical path is a small set of focused tools:
SQLite for durable local relational data, Resources/YARD for static content, and
a real password-hashing library or helper for auth. Godot Postgres plugins exist,
but I would not make temporary world servers direct Postgres clients unless the
whole persistence strategy has already moved to a client/server database.

Useful references:

- Godot-SQLite: https://github.com/2shady4u/godot-sqlite
- Godot-SQLite Asset Library: https://godotengine.org/asset-library/asset/1686
- Godot 4 PostgreSQL plugin: https://github.com/finepointcgi/godot-4-postgre-plugin
- SQLite appropriate uses: https://www.sqlite.org/whentouse.html
- SQLite isolation: https://www.sqlite.org/isolation.html
- SQLite WAL: https://www.sqlite.org/wal.html
- Godot `HTTPRequest`: https://docs.godotengine.org/en/stable/classes/class_httprequest.html
- Godot `WebSocketMultiplayerPeer`: https://docs.godotengine.org/en/stable/classes/class_websocketmultiplayerpeer.html
- OWASP Password Storage: https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
- OWASP WebSocket Security: https://cheatsheetseries.owasp.org/cheatsheets/WebSocket_Security_Cheat_Sheet.html
- PocketBase docs: https://pocketbase.io/docs/
- PocketBase Go extension overview: https://pocketbase.io/docs/go-overview/
- Postgres `NOTIFY`: https://www.postgresql.org/docs/current/sql-notify.html
- SpacetimeDB Godot tutorial: https://spacetimedb.com/docs/tutorials/godot/
- YARD resource registry: https://github.com/elliotfontaine/yard-godot

## Data Ownership Contract

| Data | Owner | Storage |
| --- | --- | --- |
| Guest sessions | Master | RAM plus optional SQLite audit/session table |
| Accounts | Master | SQLite |
| Password hashes | Master/AuthService | SQLite, using Argon2id/scrypt/bcrypt/PBKDF2 via a real library |
| Session tokens | Master | SQLite hash/revocation table plus RAM cache |
| Character profile | Master | SQLite |
| Global currency | Master | SQLite |
| Global inventory | Master | SQLite |
| Per-experience stats | Master | SQLite rows keyed by `world_key` or `experience_key` |
| Static item/world definitions | Shared content | Godot Resources, scenes, or read-only tables |
| Live movement/combat/NPC state | World server | RAM only during active world process |
| World-local temporary state | World server | RAM; optionally submit final result events |
| Chat delivery | Master | RAM/socket fanout |
| Chat history | Master | Optional SQLite append/batch table |
| Moderation/audit logs | Master | SQLite |

VirtuCade's Roblox-like experiences need namespacing. Some worlds will share the
real player profile; others will have their own mini-game state. Store that as
per-experience state rather than forcing one global character schema onto every
world.

## Suggested Master DatabaseService Shape

Keep SQL behind one module boundary.

```text
server/master/db/
  database_service.gd
  migrations/
    001_initial.sql
  repositories/
    account_repository.gd
    session_repository.gd
    character_repository.gd
    inventory_repository.gd
    world_state_repository.gd
```

Initial API sketch:

```gdscript
create_guest() -> Dictionary
register_account(username: String, password: String) -> Dictionary
login(username: String, password: String) -> Dictionary
create_world_join(player_session_id: String, world_key: String) -> Dictionary
load_world_snapshot(character_id: String, world_key: String) -> Dictionary
save_world_snapshot(command: Dictionary) -> Dictionary
apply_world_result(command: Dictionary) -> Dictionary
append_chat_message(command: Dictionary) -> void
```

World-to-master save commands should include:

- `player_session_id`
- `character_id`
- `world_key`
- `world_instance_id`
- `sequence`
- `idempotency_key`
- `snapshot_version`
- `payload`

The idempotency key matters. If a world retries a reward/save command after a
network hiccup, master must not duplicate currency, items, experience, or quest
completion.

## SQLite Configuration

Use SQLite only on local disk, owned by master.

Recommended pragmas:

```sql
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = ON;
PRAGMA synchronous = NORMAL;
```

Notes:

- `WAL` lets readers and one writer proceed concurrently, but it does not create
  multiple simultaneous writers.
- `synchronous = NORMAL` is a performance/durability tradeoff. Test whether
  `FULL` is acceptable if power-loss durability becomes more important.
- Keep transactions short.
- Batch dirty saves when possible.
- Do not hold long read transactions.
- Run checkpoint and backup tests.
- Never put the writable SQLite file on a network filesystem.

## Performance Expectation

For 100-200 CCU, the database bottleneck should not be raw SQLite if the design
avoids spam writes.

Example safe-ish write classes:

- login/register;
- world join;
- transfer save;
- dirty character save every N seconds;
- logout save;
- inventory/currency result events;
- moderation/audit append;
- optional batched chat history.

Example dangerous write classes:

- movement ticks;
- every replicated position;
- every chat delivery recipient;
- every NPC state change;
- polling inventory every frame;
- world heartbeat persisted to DB every tick.

The real risk is not "SQLite is slow." The real risk is accidentally turning the
master into a synchronous SQL endpoint on the main networking path. The
validation spike should measure p95/p99 latency for login, transfer, save, and
chat while 100-200 simulated users are active.

## When To Reject SQLite

Move the `DatabaseService` adapter to Postgres if any of these show up:

- direct writes are needed from more than one persistent backend process;
- SQLite write waits become visible under transfer/save bursts;
- global economy/trading/auction writes become central gameplay;
- customer support/admin/reporting needs grow quickly;
- website/API traffic becomes significant;
- multi-VPS deployment becomes real;
- backup/restore/checkpoint workflow feels brittle;
- a native password hashing dependency removes most of the "pure Godot" benefit
  anyway.

Move to PocketBase or another backend if:

- auth/account/admin tooling becomes the main bottleneck;
- web registration, password reset, email verification, OAuth, or dashboards are
  urgent;
- the project would rather accept a Go/PocketBase backend than hand-roll those
  systems in GDScript.

Do not move to direct world SQLite writes. If you need multi-process direct DB
writes, that is a Postgres signal.

## Validation Plan

Before persistence becomes real, build a narrow spike:

1. Add `DatabaseService` with SQLite migrations and one connection owned by
   master.
2. Add guest/session/account tables with no website integration yet.
3. Add character/world-state tables keyed by `character_id` and `world_key`.
4. Add world save/result commands with idempotency keys.
5. Add logout, transfer, and timed dirty-save flows.
6. Add backup and restore script.
7. Run synthetic tests for 100-200 active sessions:
   - concurrent guest creation;
   - login/register burst;
   - transfer storm across all discovered worlds;
   - dirty-save storm;
   - chat burst with optional history off and on;
   - master crash during transaction;
   - world crash before/after save ACK;
   - duplicate result replay;
   - expired or wrong-world join tickets.

This keeps the current workflow small while preserving the escape hatch:

```text
World protocol stays stable.
Master DatabaseService changes adapter.
SQLite can become Postgres later without teaching worlds SQL.
```
