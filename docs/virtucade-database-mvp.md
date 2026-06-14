# VirtuCade Database MVP

Date: 2026-06-12

This document describes the **implemented** database MVP: a master-owned SQLite
store, a guest system, a name-only "fake" login, and persistent player world +
position. It is the concrete first step recommended by the
[VirtuCade Database Handling Spike](virtucade-database-handling-spike.md), kept
deliberately small.

If you only read one section, read [Data Flow](#data-flow) — it explains how
identity and saves move between the three roles.

## Goals And Non-Goals

In scope (this MVP):

- Embedded SQLite via the `2shady4u/godot-sqlite` addon (HEAD / v4.7).
- The master is the **only** process that opens the database.
- Guests can join instantly, move, and chat; none of their data is saved.
- A name-only login: an existing name resumes that player; a new name starts a
  fresh one. No password.
- Player `world` + `x,y` position persist. Logging out and back in resumes the
  same world and position.
- Remote players show a name label; guests render as semi-transparent ghosts.
- Chat shows display names and works for guests and logged-in users alike.

Out of scope (intentionally):

- OAuth, passwords, or any real authentication.
- Inventory, currency, or per-experience stats (the schema is ready to grow).
- HTTPS/website auth transport (WebSocket RPC only, as today).
- Server-side movement validation.

## Architecture

```text
Client  ──MasterNet──▶  Master ──▶ DatabaseService ──▶ SQLite (master disk)
   │                      ▲  ▲
   │                      │  └────── save_player_state ───── World server
   └──WorldNet──────────▶ World server (live gameplay, position authority)
```

- **Client**: connects to the master instantly and joins the hub. A bottom-right
  widget offers an optional login. Never talks to the database.
- **Master**: owns sessions, accounts, and the single SQLite connection. Issues
  world join tickets carrying player identity, and commits position saves.
- **World server**: authoritative for live gameplay/position. Reports player
  positions to the master; never touches SQL.

This matches the spike's core rule: *live simulation state lives in memory;
durable truth is committed through one controlled boundary (the master).*

## The Addon

`addons/godot-sqlite/` vendors `2shady4u/godot-sqlite` (`gdsqlite.gdextension`,
`compatibility_minimum = 4.5`, works on Godot 4.6.3). Only the **Windows x86_64**
(development) and **Linux x86_64** (VPS target) binaries are committed; add other
platform binaries from the upstream `bin.zip` release if you export elsewhere.
The `SQLite` class is registered by the GDExtension and is available at runtime
without enabling the editor plugin.

## Schema

One table for the MVP. Migrations are embedded in `database_service.gd` (not
shipped as `.sql` files, because Godot strips non-resource files from exports).

```sql
CREATE TABLE accounts (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT NOT NULL,
    username_lower TEXT NOT NULL UNIQUE,   -- case-insensitive login
    world_key     TEXT NOT NULL DEFAULT 'hub',
    pos_x         REAL NOT NULL DEFAULT 0,
    pos_y         REAL NOT NULL DEFAULT 0,
    has_position  INTEGER NOT NULL DEFAULT 0,  -- 0 until first real save
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
);
```

The database file is `user://virtucade.db` (the master's local user data
directory), opened with the spike's recommended pragmas: `journal_mode = WAL`,
`busy_timeout = 5000`, `synchronous = NORMAL`.

## Identity Model

Every connected client gets a **guest session** the moment it connects
(`Guest-<n>`). A session is just RAM on the master:

```text
session = { account_id, display_name, is_guest, active_world_key }
```

- **Login** (`AccountEndpoint.login(name)`): the name is sanitized, then
  `get_or_create` looks it up case-insensitively. The session is promoted to the
  account and the master tells the client which world to resume into.
- **Logout**: the session reverts to a fresh guest and the client is resumed into
  the hub. The last position was already saved (see below), so logging back in
  restores it.

Guest names are reserved (`guest-` prefixed names are rejected at login) so a
player cannot impersonate the guest namespace.

## Data Flow

### Identity into a world

Worlds need each player's name and guest flag to render labels/ghosts, and a
spawn position. All of this rides the **existing world join ticket** rather than
a new channel:

1. The master issues a join ticket for a peer entering `world_key`.
2. At that moment it attaches the session identity (`display_name`, `is_guest`)
   and any server-known saved spawn position.
3. The world bakes these into the player's **spawn data**, which Godot's
   `MultiplayerSpawner` replicates to every peer.
4. `player.gd` reads them: it ghosts the sprite for guests and shows the name
   label on remote players only.

The client never sends its own name into the world, and never sends raw spawn
coordinates — both are master-owned.

### Position saves (world → master)

The world server is the position authority. It reports positions to the master:

- **periodically** (every 3s), and
- **on disconnect** (read just before the player node is removed).

The master decides what is durable in `AccountEndpoint.save_position`:

- guests are skipped;
- the save is accepted only if its `world_key` matches the world the master
  currently believes the player is in (`active_world_key`).

That second check kills a classic race: a naive "save on disconnect" writes the
world you are *leaving* as your current world. The master commits
`active_world_key` only after the target world confirms the join ticket was
consumed, so a late save from the previous world is rejected without moving the
session ahead of a failed resume or transfer.

### Resume on login

On login the master reads the account's saved `world_key` + position from SQLite
and stores them as a one-shot **resume intent**. It tells the client to enter
that world; when the client requests the join, the master attaches the saved
position as a server-authoritative spawn override. The client re-enters the world
(see below) and spawns exactly where it left off.

## Login While Already In A World

Logging in (or out) re-enters the resumed world by reusing the normal
world-join path:

- If the saved world **differs** from the current one, it is an ordinary world
  switch.
- If the saved world is the **same** (e.g. you log in while standing in the
  hub), the client cleanly re-joins the same world; the player respawns at the
  saved position with the new identity (name label + no-ghost).

A subtle bug surfaced and was fixed here: re-entering the *same* world must
detach the old world scene synchronously (`remove_child` before `queue_free`),
otherwise the still-pending old scene collides node names with the new one,
Godot renames the new root, and `MultiplayerSpawner` path matching breaks so
players never replicate. See `client.gd:_load_world_scene`.

## Chat

The master substitutes the sender's session display name into every broadcast
(`ChatEndpoint`), so chat reads as `Alice: hi` / `Guest-3: hi` and works
identically for guests and logged-in users.

## Files

| File | Role |
| --- | --- |
| `addons/godot-sqlite/` | Vendored SQLite GDExtension (HEAD / v4.7). |
| `server/master/db/database_service.gd` | Single SQLite connection, pragmas, embedded migrations. |
| `server/master/db/account_repository.gd` | Name-only account CRUD + position updates. |
| `shared/net/account_endpoint.gd` | Sessions, guest creation, login/logout, save validation. |
| `shared/net/master_endpoint.gd` | Join-ticket identity + spawn override, `save_player_state`, resume intent. |
| `shared/net/chat_endpoint.gd` | Broadcasts display names. |
| `server/world/world.gd` | Bakes identity into spawns; periodic + disconnect position saves. |
| `shared/world/world.gd` | Spawn data carries identity; `player_position()` accessor. |
| `shared/player/player.gd` / `.tscn` | Name label (remote-only) + ghost (guests). |
| `client/login/login_panel.gd` / `.tscn` | Bottom-right login widget. |
| `client/client.gd` | Login wiring, resume handling, chat names. |
| `tools/run_db_test.ps1` | End-to-end login/persistence test. |

## How To Test

End-to-end (two client phases, master restarted in between to prove on-disk
persistence):

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_db_test.ps1
```

Success prints `DBTEST_PASS`. The test creates an account, travels to
`left_world`, parks at a known position, restarts the master, logs in again, and
asserts it resumed into `left_world` at that exact position.

The original topology smoke test still passes unchanged (guests only):

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_smoke.ps1
```

Manual: run a master plus two visible clients (see the README "Editor Run
Instances" section). Each client starts as a guest (ghost). Click **Log In**
(bottom-right), enter a name, move around, then transfer worlds or close and
relaunch — logging in with the same name resumes your world and position. The
other client sees your name above your character.

Inspect the database with any SQLite tool, e.g.:

```text
%APPDATA%\Godot\app_userdata\multi-server-test\virtucade.db
```

## Known Limitations

- No passwords or real auth — anyone can log in as any existing name.
- Position is saved at most every 3s while connected, so an ungraceful crash can
  lose up to ~3s of movement.
- World server peers also receive a throwaway guest session on the master
  (they connect to MasterNet to register); harmless but it consumes guest
  numbers.
- Single SQLite writer (the master). See the spike for when to move to Postgres.

## Future Work

- Real authentication (password hashing per OWASP, then HTTPS/website transport).
- Additional tables (inventory, currency, per-experience state) — the
  `DatabaseService` migration list and repository pattern are ready for them.
- A reusable `world_player_state` table keyed by `(account_id, world_key)` if
  per-world save data (not just last position) is needed.
- Backup/restore tooling and a periodic checkpoint job.
