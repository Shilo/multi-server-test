# Godot Resource Database Wrapper Spike

This spike asks whether VirtuCade could use Godot `Resource` files as the
primary database for a small-scale MMO instead of SQLite, PocketBase, or another
database service.

The strongest version of the idea is not "save one giant `.tres` file." The
strongest version is a RAM-first, single-writer database service inside the
Godot master server, with sharded Resource records, explicit indexes, a
write-ahead command log, crash-tested snapshots, migrations, backup rotation,
and strict security boundaries.

That version is possible. It is also no longer "just Resources." It is a custom
database engine whose snapshots happen to be Godot Resources.

## Short Recommendation

Do not choose a Resource-only database as the default production path yet.

The better production-shaped default for 100-200 CCU is still:

- Godot-native `Resource` files for static game content: items, classes, skills,
  NPC templates, quests, world definitions, spawn tables, balance data.
- A master-owned storage interface for live mutable data.
- SQLite as the first serious durable backend for accounts, characters, guilds,
  chat history, moderation/audit logs, and indexed lookups.
- Optional Resource-backed storage as a deliberately constrained experimental
  backend for accounts/characters only, behind the same storage interface.

The Resource-only path is worth a small validation spike if the workflow benefit
is emotionally and practically important. It must be tested as a real database,
not as a save-game convenience layer.

## Why This Needs Challenging

Your attraction to Resources is legitimate:

- They are native Godot objects.
- They are editor-visible and typed.
- They avoid a separate database service.
- They keep client, master, world, and data definitions in one project.
- They match old file-backed MMO intuition: keep state in RAM and periodically
  serialize to disk.

But the counterargument is strong:

- Once you need uniqueness constraints, indexed search, audit history, durable
  transactions, backups, migrations, and crash recovery, SQLite may be less code
  than rebuilding those features around Resource files.
- Tiny MMO's history points exactly this way: Resources were kept for the small
  master account collection, but world/player/guild/chat data moved to SQLite.
- SpacetimeDB validates RAM-first authoritative state, but it does not validate
  whole-file Resource saves. Its RAM-first model is paired with a commit log,
  transactions, indexes, subscriptions, and recovery.

## Tiny MMO Evidence

Local repo reviewed:

`C:\Programming_Files\Godot\godot-tiny-mmo`

Important commits:

| Commit | Evidence | Meaning |
|---|---|---|
| `95b1c78c` | Added early Resource-backed world database files with account/player dictionaries. | The project initially explored Resources as live world persistence. |
| `3c222991` | Reworked world persistence into `WorldPlayerDataResource`, character creation/lookups, and save-on-close. | Resource DB was not just static content; it was used for live player data. |
| `19a154f0` | Fixed issue `#45` by saving `account_collection` on account creation and on tree exit. | Account Resources were losing newly-created accounts unless save policy was explicit. |
| `86c34479` | Removed hundreds of registered test accounts from the tracked Resource file. | Mutable `.tres` database files polluted git history. |
| `b8891148` | Ignored/untracked `account_collection.tres`. | The project had to treat Resource DB files as runtime state, not source assets. |
| `6032c83e` | Deleted Resource world DB files and added `addons/godot-sqlite`, `world_database.gd`, `world_schema.gd`, `world_store_sqlite.gd`, and SQLite chat storage. | World/player/guild/chat data crossed the line where SQLite became more attractive. |
| `d06db018` | Fixed export path issues by moving account persistence to `user://master/account_collection.tres` outside editor. | `res://` is not a production write path in exported builds. |

Issue [SlayHorizon/godot-tiny-mmo#45](https://github.com/SlayHorizon/godot-tiny-mmo/issues/45)
is the clearest discussion. The maintainer accepted save-on-create as a
temporary workaround, but explicitly warned against saving on every change in
production and suggested periodic saves, threshold saves, tree-exit saves, and a
proper shutdown command. They also said Resources are practical for testing,
prototyping, and a few hundred users, but not ideal for large-scale projects.

Current Tiny MMO architecture is hybrid:

- Master account data is still Resource-backed:
  - `source/server/master/account_models/account_collection.gd`
  - `source/server/master/account_models/account.gd`
  - `source/server/master/components/authentication_manager.gd`
- World data is SQLite-backed:
  - `source/server/world/database/world_database.gd`
  - `source/server/world/database/world_schema.gd`
  - `source/server/world/database/world_store_sqlite.gd`
  - `source/server/world/components/chat/chat_store_sqlite.gd`

That is not proof that Resources are useless. It is proof that a monolithic
Resource world database became awkward once the project added players, guilds,
chat, flags, block lists, profiles, history, migrations, indexes, backups, and
moderation-style queries.

## Godot Facts That Matter

Official docs confirm Resources are a real serialization mechanism, but not a
database system.

- [`ResourceSaver`](https://docs.godotengine.org/en/stable/classes/class_resourcesaver.html)
  saves Resources to text `.tres/.tscn` or binary `.res/.scn` files through
  registered format savers. It returns an error code on save.
- Runtime-generated Resource UIDs are not saved by normal runtime saves because
  that UID-writing path is editor-only.
- [`ResourceLoader`](https://docs.godotengine.org/en/stable/classes/class_resourceloader.html)
  caches resources by path. `CACHE_MODE_IGNORE`, `CACHE_MODE_REPLACE`, and
  deep variants matter if a database manager needs to prove it loaded fresh
  bytes from disk rather than getting an in-memory cached object.
- [`user://`](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html)
  is the correct persistent write path. `res://` is likely read-only in exported
  builds.
- Godot's
  [thread-safe API docs](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html)
  warn that modifying the same unique Resource from multiple threads is not
  supported. A Resource DB should use one IO/mutation owner.
- [`FileAccess.flush()`](https://docs.godotengine.org/en/stable/classes/class_fileaccess.html)
  can force file buffers out periodically, but constant flushing reduces
  performance. This matters for a write-ahead log.
- `FileAccess.get_var(allow_objects=true)` warns that deserialized objects can
  execute code. Resource loading has the same practical trust-boundary concern
  when loading `.tres/.res` from untrusted paths.

## Ecosystem Scan

I did not find a mature library that turns Godot Resources into a production MMO
database. I found useful partial tools:

| Tool | What it helps with | Why it does not solve live MMO persistence |
|---|---|---|
| [YARD - Yet Another Resource Database](https://store.godotengine.org/asset/elliotfontaine/yard-yet-another-resource-database/) / [GitHub](https://github.com/elliotfontaine/yard-godot) | Resource registries, stable string IDs, spreadsheet-like editor, baked property indexes, selective/threaded loads. | Excellent for static content catalogs. It explicitly leaves loading control to you and does not provide transactions, WAL, crash recovery, or mutable account/character persistence. |
| [Resource Databases](https://github.com/DarthPapalo/ResourceDatabases) | Godot editor database for resource collections, categories, filters, runtime lookup, UID/path references. | Again strongest for content management, not authoritative live-state persistence. |
| [Godot Resource Groups](https://github.com/derkork/godot-resource-groups) | Bulk loading resources by groups/patterns without hard-coding paths. | Useful for discovery and catalogs, not a database engine. |
| [Pandora](https://github.com/bitbrain/pandora) | RPG data management for items, inventories, spells, mobs, quests, NPCs. | A content/data authoring layer, not durable server storage. |
| [SaveKit](https://github.com/fernforestgames/godot-savekit) | Save/load game state with pluggable JSON/binary formats and Resource support. | Built for save games, not multi-record MMO durability, indexing, account security, or server-side transactions. |
| [Save Made Easy](https://github.com/AdamKormos/SaveMadeEasy) | Simple save/load plugin with nested variables, Resources, and encryption. | Client/local-save shaped, not an authoritative MMO database. |
| [Godot Safe Resource Loader](https://github.com/derkork/godot-safe-resource-loader/) | Safer loading of untrusted `.tres` files by scanning for embedded scripts and unsafe external links. | Mitigates one security risk, but does not provide persistence semantics. |

The ecosystem signal is clear: people use "Resource database" to mean static
resource catalog, content editor, lookup table, or save-game graph. I did not
find evidence of a widely-used Resource-only MMO account/character/chat database
with production durability.

## Old File-Backed MMO Lesson

File-backed online games are not imaginary. Older MUD/MMO-style systems often
loaded static world data from structured files and kept active state in memory.
CircleMUD-style world files split content into `.wld`, `.mob`, `.obj`, `.shp`,
and `.zon` files, as described in the
[CircleMUD builder manual](https://www.circlemud.org/cdp/building/building-2.html).

The useful lesson is constrained:

- File-backed works best for static or low-churn records.
- One authoritative process owns mutation.
- Records are loaded into RAM.
- Saves are deliberate and operationally disciplined.
- Tooling grows over time because raw files become hard to inspect, query, and
  migrate.

Modern successors such as
[Intersect Engine](https://docs.freemmorpgmaker.com/en-US/developer/advanced/database/)
use formal databases for game data and player data because relationships,
migrations, tooling, and moderation workflows become valuable.

## SpacetimeDB Lesson

[SpacetimeDB](https://spacetimedb.com/docs/intro/what-is-spacetimedb/) supports
the RAM-first instinct. Its docs describe state held in memory while committed
transactions are persisted to a commit log and recovered after restart or crash.
Reducers run inside database transactions with isolation, atomicity, and
rollback guarantees, and the
[commit log](https://spacetimedb.com/docs/reference/internals/commitlog/) stores
durable transaction data.

The translation for Godot is:

- Keeping MMO state in RAM is reasonable.
- Periodic snapshots are not enough for production durability.
- A real RAM-first database needs a write-ahead log, transaction boundaries,
  replay, integrity checks, and schema migration.

If a Godot Resource DB wrapper copies the SpacetimeDB idea, the important part
is not Resources. The important part is WAL plus snapshots plus deterministic
replay.

## Strongest Resource-Only Design

If we intentionally try Resource-only persistence, this is the least-fragile
shape.

```text
user://db/
  manifest.res
  journals/
    00000000000000000000.log
    00000000000000100000.log
  snapshots/
    snapshot_00000000000000125000.res
  records/
    accounts/00/account_000001.res
    accounts/00/account_000002.res
    characters/00/character_000001.res
    guilds/00/guild_000001.res
  indexes/
    username_to_account_id.res
    character_name_to_character_id.res
    account_to_character_ids.res
    guild_name_to_guild_id.res
  backups/
```

Core rules:

- One `DatabaseService` node owns all persisted data.
- Master is the only process that writes account/character/global records.
- World servers send validated persistence commands to master; they never call
  `ResourceSaver.save()` directly for shared durable state.
- Live records stay in RAM.
- All mutations are commands, not arbitrary object edits.
- Before applying a command, append it to a journal segment and flush according
  to durability policy.
- After replay-safe journal append, apply the mutation to RAM, update in-memory
  indexes, and mark touched records dirty.
- Dirty records are saved as sharded `.res` snapshots on logout, every N
  seconds, after N dirty records, and on graceful shutdown.
- Use temp-file write, close/flush, load-verify with `CACHE_MODE_IGNORE`, then
  replace the canonical file.
- Rotate backups and keep enough journal history to recover from the newest
  valid snapshot.
- Every persisted Resource includes `schema_version`, `record_id`, `revision`,
  `updated_at_ms`, and a checksum or journal revision marker.
- All schema migrations are explicit functions from old Resource versions to
  current Resource versions.
- All indexes are either rebuilt from records at startup or verified against
  record revisions.
- Passwords are never plaintext. Use a proper password hashing strategy and
  store hash metadata, not raw credentials.
- Never load Resource files supplied by clients. Runtime database files are
  trusted server-owned files only.

### Minimal API Shape

```gdscript
class_name DatabaseService
extends Node

func start() -> void
func stop_gracefully() -> void

func create_account(username: String, password: String) -> AccountRecord
func authenticate(username: String, password: String) -> AccountRecord
func create_character(account_id: int, data: Dictionary) -> CharacterRecord
func load_character(character_id: int) -> CharacterRecord
func save_character_patch(character_id: int, patch: Dictionary) -> void
func transfer_character(character_id: int, from_world: String, to_world: String) -> TransferRecord
func append_chat_message(channel_id: String, sender_id: int, text: String) -> ChatMessageRecord
```

The implementation should forbid callers from receiving direct mutable access to
records unless the database service can track the mutation. If code can mutate a
Resource object without going through the command path, the journal and indexes
can lie.

## What The Wrapper Can Reduce

A good Resource DB manager can reduce these Resource-specific problems:

- Whole-world save cost: shard into per-record files instead of one giant
  Resource.
- Cache confusion: centralize `ResourceLoader` cache modes and verification
  loads.
- Save timing: centralize dirty tracking, timers, threshold flushes, and
  shutdown saves.
- Export path bugs: always write under `user://` in production.
- Git pollution: runtime DB paths stay ignored and outside source content.
- Index drift: make indexes first-class files with rebuild/verify paths.
- Migration chaos: force `schema_version` and migration functions per record
  type.
- Crash damage: temp writes, backups, journal replay, and snapshot verification.

## What The Wrapper Cannot Magically Reduce

These are real database problems, not Resource inconveniences:

- Query language: every query is custom code.
- Transactions across multiple records: you must define atomic command batches
  and rollback/replay semantics.
- Constraints: uniqueness and foreign-key-like rules are custom indexes and
  custom validation.
- Audit/history: append-only records or logs must be designed.
- Backup/restore: you need tooling and tests.
- Migration safety: old file compatibility is your job.
- Moderation tooling: searching chat, trades, suspicious inventory changes, and
  account history is much easier in SQL.
- Data exports: external tools understand SQLite immediately; they do not
  understand custom `.res` record graphs.
- Cross-process writers: do not do this. The Resource DB shape assumes one
  writer process.

## Data-Type Fit Matrix

| Data | Resource-only fit | Why |
|---|---:|---|
| Item definitions | Excellent | Static, typed, editor-authored, low churn. |
| Skill/class definitions | Excellent | Same as item definitions. |
| NPC templates and spawn tables | Excellent | Content catalog, not player-owned state. |
| Map/world definitions | Good | Great as authored data; not ideal for high-churn dynamic world state. |
| Accounts | Possible, risky | Small records fit, but auth security, username uniqueness, password migration, lockout/audit, and recovery matter. |
| Characters | Possible | Per-character files are plausible if writes are command-based and indexed. |
| Inventory | Possible early, risky later | Simple arrays fit; economy/audit/trade duplication prevention pushes toward transactions. |
| Guilds | Possible early | Membership indexes and permissions become custom. |
| Friends/block lists | Possible early | Queries and account lookup indexes grow. |
| Chat history | Poor | Append/query/moderation history is a natural SQL/log use case. |
| Mail/trades/auction house | Poor | Needs transactions, audit, uniqueness, anti-duplication, and query tooling. |
| Moderation/audit logs | Poor | Append-only log or SQL table is better. |
| Leaderboards | Poor | Needs sorting, filtering, time windows, and anti-abuse checks. |

## Resource-Only Acceptance Tests

Do not accept Resource-only persistence without these tests:

1. Load 1,000, 10,000, and 100,000 accounts plus characters into RAM.
2. Save 1,000 dirty character records and measure wall time and frame hitches.
3. Append 100,000 mutation log entries and replay from snapshot plus journal.
4. Kill the process during journal append, during record temp write, during
   replacement, and during index write.
5. Prove recovery chooses the last valid snapshot and journal prefix.
6. Prove a corrupted record can be quarantined without destroying the whole DB.
7. Simulate duplicate username/character-name creation in the same frame.
8. Simulate character transfer while the world server crashes mid-save.
9. Migrate old `schema_version` records to new classes and verify every index.
10. Compare `.tres`, `.res`, binary `FileAccess.store_var`, JSON, and SQLite
    for size, save time, load time, and inspection workflow.
11. Run a 100-200 CCU script that performs login, character selection, travel,
    inventory changes, chat, and logout.
12. Restore from backup on a clean machine.

If this sounds like too much for the first persistence step, that is the point:
SQLite already gives many of these properties in a smaller and better-tested
package.

## Best Near-Term Spike

Build a storage interface first, then test both backends.

```text
MasterServer
  DatabaseService
    AccountStore
    CharacterStore
    ChatStore
    AuditStore
```

Spike A: `ResourceObjectStore`

- Accounts and characters only.
- Sharded per-record `.res` files.
- In-memory indexes.
- Write-ahead command journal using `FileAccess`.
- Snapshot and replay.
- Crash/recovery tests.

Spike B: `SQLiteStore`

- Same API.
- SQLite database under `user://db/`.
- WAL mode if the plugin supports it cleanly.
- Migrations, indexes, and backup flow.

Then compare workflow and measurements. If Resources win in actual tests, use
them with confidence. If they lose, the loss will be specific rather than
ideological.

## Decision Pressure

Use Resources as the only production database only if all are true:

- One master process owns every durable write.
- CCU stays small and vertically scaled.
- Live mutable data is modest enough to keep in RAM.
- You accept writing and maintaining journal/replay/index/migration tooling.
- Chat, audit, moderation, mail, trading, and leaderboard data are either tiny
  or handled by a separate append-only/log backend.
- Operational tooling can be built inside Godot or tolerated as custom scripts.

Use SQLite if any are true:

- You need chat history or moderation search.
- You need account, character, guild, or inventory queries beyond direct ID
  lookup.
- You want durable multi-record transactions.
- You want standard backup/inspection/export tooling.
- You want fewer custom persistence invariants to maintain.

My challenged conclusion: Resources are excellent for VirtuCade's content layer
and plausible for a constrained RAM-first account/character object store. They
are not yet the responsible default for the whole production database. If we try
them, we should try the strongest version: command log plus sharded Resource
snapshots, tested directly against SQLite.

## Source Links

- [Godot Tiny MMO repository](https://github.com/SlayHorizon/godot-tiny-mmo)
- [Godot Tiny MMO issue #45](https://github.com/SlayHorizon/godot-tiny-mmo/issues/45)
- [Godot Tiny MMO `19a154f0` account Resource save fix](https://github.com/SlayHorizon/godot-tiny-mmo/commit/19a154f0)
- [Godot Tiny MMO `6032c83e` SQLite migration](https://github.com/SlayHorizon/godot-tiny-mmo/commit/6032c83e0cfde0c369043b884b7758d2d1739cab)
- [Godot ResourceSaver docs](https://docs.godotengine.org/en/stable/classes/class_resourcesaver.html)
- [Godot ResourceLoader docs](https://docs.godotengine.org/en/stable/classes/class_resourceloader.html)
- [Godot data paths docs](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html)
- [Godot thread-safe APIs docs](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html)
- [Godot FileAccess docs](https://docs.godotengine.org/en/stable/classes/class_fileaccess.html)
- [SQLite appropriate uses](https://www.sqlite.org/whentouse.html)
- [SQLite isolation](https://www.sqlite.org/isolation.html)
- [SpacetimeDB overview](https://spacetimedb.com/docs/intro/what-is-spacetimedb/)
- [SpacetimeDB commit log](https://spacetimedb.com/docs/reference/internals/commitlog/)
- [SpacetimeDB reducers](https://spacetimedb.com/docs/functions/reducers/)
- [YARD Resource Database](https://store.godotengine.org/asset/elliotfontaine/yard-yet-another-resource-database/)
- [Resource Databases plugin](https://github.com/DarthPapalo/ResourceDatabases)
- [Godot Resource Groups](https://github.com/derkork/godot-resource-groups)
- [Pandora RPG data management](https://github.com/bitbrain/pandora)
- [SaveKit](https://github.com/fernforestgames/godot-savekit)
- [Save Made Easy](https://github.com/AdamKormos/SaveMadeEasy)
- [Godot Safe Resource Loader](https://github.com/derkork/godot-safe-resource-loader/)
- [CircleMUD builder manual](https://www.circlemud.org/cdp/building/building-2.html)
- [Intersect database docs](https://docs.freemmorpgmaker.com/en-US/developer/advanced/database/)
