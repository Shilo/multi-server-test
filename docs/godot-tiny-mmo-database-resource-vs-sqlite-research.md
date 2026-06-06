# Godot Tiny MMO Database Research: Resources Vs SQLite

This note answers a narrow but important question for future small MMO work:

Can a Godot MMO use Godot `Resource` files as the database if one master server
owns all database reads and writes, or is SQLite worth the extra complexity?

Short answer: a Resource-only database is viable for a deliberately small,
single-writer mini-MMORPG if it is designed as a careful file-backed object
store. It is not automatically foolish. It is also not the same thing as a real
database. Godot Tiny MMO is useful evidence because it first used Resources for
world persistence, explicitly documented the simplicity tradeoff, and later
migrated world/player/guild/chat storage to SQLite while keeping master accounts
Resource-backed.

For this project's current spike, persistence should stay out of scope. For the
next persistence spike, the safest path is a thin storage interface with either:

- Resource-backed object files for accounts/characters first.
- SQLite for chat history, guild/social queries, search, migrations, and audit
  tooling once those needs appear.

## Research Scope

Reviewed sources:

- Local Godot Tiny MMO checkout: `C:\Programming_Files\Godot\godot-tiny-mmo`.
- Godot Tiny MMO commit history, branches, and source files.
- Godot Tiny MMO GitHub issue tracker, especially issue
  [#45](https://github.com/SlayHorizon/godot-tiny-mmo/issues/45).
- Godot Tiny MMO public docs and `gh-pages` documentation branch.
- Official Godot `ResourceSaver`, `ResourceLoader`, `FileAccess`, and data path
  docs.
- Official SQLite docs on serverless operation, appropriate uses, isolation, and
  write concurrency.
- Official SpacetimeDB docs on in-memory state, commit logs, reducers,
  subscriptions, and language support.
- Intersect Engine docs/repo/issues.
- Eclipse Origins source.
- Elysium, Mirage, and XtremeWorlds public source/documentation where available.
- Subagent sidecar reviews for Godot Tiny MMO archaeology, SpacetimeDB, and
  legacy 2D MMO storage patterns.

## Bottom Line

| Option | Best fit | Main risk | My read for a scalable mini-MMORPG |
|---|---|---|---|
| Godot Resources | Static game data, simple single-writer account/character object records, editor-friendly tuning data | Whole-file/object save semantics, weak querying, no built-in transactions, custom migrations, crash-save discipline | Viable if sharded into many small files and owned by one database service. Risky as one giant `.tres`. |
| SQLite | One authoritative server process with local durable data, relational lookups, chat history, guilds, indexes, migrations | One writer per database file, addon/native export concerns, schema work | Strong default once social/chat/history/search/query needs appear. Still simple compared with Postgres. |
| PostgreSQL/MySQL | Multiple app servers, operational tooling, remote DB, high concurrent writes, reporting/mod tools | More infrastructure and operational knowledge | Better later, not needed for this spike. |
| SpacetimeDB | Replacing the backend with a database/server/realtime-sync system | RAM-bounded state, reducer model, no official Godot happy path found | Conceptually validates RAM-first authoritative state, but it is a platform choice, not a small Godot storage tweak. |

## What Godot Tiny MMO Actually Does Now

Godot Tiny MMO's current README says it has SQLite persistence for players,
guilds, and chat. The current local source matches that:

- `source/server/world/database/world_database.gd` owns the SQLite file path.
  In editor it uses `res://source/server/world/data/<world>.db`; in exports it
  uses `user://db/<world>.db`.
- `source/server/world/database/world_schema.gd` creates `accounts`, `players`,
  `guilds`, `guild_members`, `flags`, `conversations`, and `messages`.
- `source/server/world/database/world_store_sqlite.gd` handles player/guild
  load and save operations and exposes explicit `BEGIN`, `COMMIT`, and
  `ROLLBACK` helpers used by selected request handlers. Not every core store
  method wraps itself in a transaction.
- `source/server/world/components/chat/chat_store_sqlite.gd` persists
  conversations and messages.
- `source/server/world/database/world_database.gd` has backup support under
  `user://db_backups`.

But master accounts are still Resource-backed:

- `source/server/master/components/authentication_manager.gd` owns an
  `AccountResourceCollection`.
- In editor it reads/writes
  `res://source/server/master/account_collection.tres`.
- In exports it uses `user://master/account_collection.tres`, because exported
  `res://` is not writable.
- `source/server/master/account_models/account_collection.gd` is a `Resource`
  with an exported account dictionary and `next_account_id`.
- `source/server/master/account_models/account.gd` is a `Resource` with account
  fields.

So Tiny MMO's present design is hybrid: SQLite for world data and chat,
Resources for the small master account collection.

Security caveat: Tiny MMO's current Resource-backed account store is useful
persistence evidence, not authentication guidance. The inspected source stores
and compares account passwords directly. Do not copy that model into a real
project; use password hashing and a deliberate auth design.

## Tiny MMO History: Resources First, SQLite Later

The important migration commit is:

- `6032c83e0cfde0c369043b884b7758d2d1739cab`
- Message: `Migrate to SQLite database and refactor related content`
- Date in local repo: 2026-01-29

That commit:

- Added `addons/godot-sqlite`.
- Deleted the old Resource world database script.
- Deleted sample Resource database files like `classic.tres` and `hardcore.tres`.
- Added `world_database.gd`, `world_schema.gd`, `world_store_sqlite.gd`, and
  `chat_store_sqlite.gd`.

Immediately before that migration, Tiny MMO's `WorldPlayerData` was a
Resource-backed whole-world data object with exported dictionaries for accounts,
players, roles, guilds, and ids. The source comment is the most important
evidence: Tiny MMO's author said they could not recommend Resources as a whole
database, but used them for the demonstration because it was interesting to keep
the setup Godot-only and minimal.

That supports a careful reading:

- Resources were chosen because they kept the project simple and reproducible.
- Resources were not presented as a scalable end-state for all world data.
- SQLite arrived after the project accumulated more persistence surface area.

The public docs are slightly stale and ambiguous compared with current source.
The `gh-pages` home page still lists `Godot as Database` as a feature, while the
current README lists `SQLite persistence (players, guilds, chat)`. The
`next_level` note says the project intentionally avoided external databases to
keep a single-tool Godot stack. Current source does use an added SQLite library,
but it still avoids a separate database service because SQLite is embedded in
the Godot server process.

## Issue Tracker Evidence

Godot Tiny MMO issue
[#45](https://github.com/SlayHorizon/godot-tiny-mmo/issues/45) is directly about
Resource-backed account persistence.

The issue reported that accounts appeared to exist only while the server was
running. A contributor suggested saving the Resource on `create_account()` so a
server crash or shutdown would not lose newly-created accounts. SlayHorizon
acknowledged that accounts were not being saved automatically, added a temporary
save-on-create workaround, and gave the key guidance:

- Saving on every change is not recommended for production.
- Better approaches include periodic saves, threshold-based saves,
  `tree_exiting`, and a proper shutdown command.
- Resources as a database are not ideal for large-scale projects.
- Resources can be practical for testing, prototyping, and supporting a few
  hundred users.
- Even without saving every create, the account collection remains usable in RAM
  while the server process is alive.

That is exactly the tradeoff you are asking about: if one process owns the
database and keeps data in RAM, Resource-backed persistence can work, but the
save policy becomes part of the database design.

## Godot Resource Files As Persistence

Official Godot docs define `ResourceSaver` as a singleton for saving Resources
to the filesystem and note that it can save text-based files like `.tres` and
binary files like `.res`. `ResourceLoader.load()` loads a Resource by path and
caches the result. Godot's path docs also say persistent data should use
`user://`, because an exported project's filesystem will likely be read-only,
while `user://` is guaranteed writable.

So Godot Resources are a real serialization mechanism. They are not just editor
metadata. But they do not provide database semantics by themselves.

### What Resources Are Good At

- Static content: item definitions, skills, classes, NPC templates, maps, spawn
  tables, damage formulas, tuning data.
- Editor-authored data that designers can inspect.
- Small runtime save files.
- Simple object-shaped data where loading the whole record makes sense.
- Single-writer persistence when all IO is owned by one service.

### What Resources Are Bad At

- Ad hoc queries like "find every character in this guild".
- Chat history, moderation logs, mail, auctions, leaderboard history, and audit
  trails.
- Many small updates to one huge file.
- Multi-process writers.
- Schema migrations across many changing record shapes.
- Crash recovery unless you build temp-file, backup, and verification logic.
- Untrusted save files if you allow arbitrary Resource loading from players.

The scary part is not "Resource files"; the scary part is "one giant
Resource file as the whole world database".

## If One Master Server Owns All Database Writes

Your idea is valid:

One master server can keep database state in RAM and serialize it to disk on a
controlled schedule.

That eliminates the biggest danger of file-backed persistence: multiple writers
touching the same files. Old 2D MMO engines survived for years with exactly that
shape: one authoritative server, in-memory structs, periodic saves, and binary
files on disk.

The remaining problems are different:

- Data loss window: if you save every 5 minutes, a crash can roll back up to 5
  minutes of changes.
- Save hitching: large Resource saves can stall the server unless you keep files
  small or move IO off the main gameplay path.
- File corruption: writing directly over the canonical file can leave a bad file
  after a crash mid-write.
- Query cost: RAM lookup is fast if you maintain indexes, but every index is now
  custom code you must keep correct.
- Migration cost: changing Resource class fields is easy early and annoying
  later when old files need conversion.
- Backup/restore: you must define backup rotation, restore validation, and
  corrupted-file recovery.
- Operational tooling: SQL viewers, migrations, reports, moderation searches,
  and exports do not come for free.

That does not make Resource persistence impossible. It means you should design
it as an object store, not as "save the whole game in one `.tres`".

## A Viable Resource-Only Mini-MMORPG Pattern

If you want to try Resource-only persistence, this is the version I would test:

```text
user://db/
  meta.tres
  indexes/
    usernames.tres
    character_names.tres
  accounts/
    account_000001.res
    account_000002.res
  characters/
    character_000001.res
    character_000002.res
  guilds/
    guild_000001.res
  backups/
```

Rules:

- One `DatabaseService` node owns all file IO.
- No gameplay system calls `ResourceSaver.save()` directly.
- All writes are submitted as commands to the database service.
- Keep live data in RAM.
- Track dirty records by id.
- Flush on logout, flush every N seconds, flush after N dirty records, and flush
  on graceful shutdown.
- Save to a temp path, verify the saved file can be loaded, then replace the
  canonical file.
- Control `ResourceLoader` cache behavior when verifying or recovering files.
  Loading the same path with the default cache can give you the in-memory object
  you already had, not proof that the newly-written file is good.
- Keep backup copies before replacing important records.
- Store `schema_version` in every persisted Resource.
- Write explicit migrations from old Resource versions to new Resource versions.
- Keep indexes as separate Resources or rebuildable files.
- Never store passwords in plaintext.
- Do not load Resource files supplied by clients.
- Use `.res` for runtime persistence unless human-readable `.tres` is truly
  useful.

This can scale much farther than a single monolithic `account_collection.tres`
because the save cost is per dirty object, not per world. It also resembles how
old file-backed engines worked: many small files plus one authoritative process.

## Where SQLite Starts Paying For Itself

SQLite becomes worth the complexity when the project grows into data that wants
queries, constraints, or history:

- Chat history.
- Direct messages.
- Guild membership.
- Player search.
- Character name uniqueness.
- Login audit and moderation history.
- Mail.
- Auctions or trading.
- Leaderboards.
- "Show all characters on this account".
- "Show all members in this guild".
- "Find all messages from this sender this week".

SQLite's official docs frame it as a replacement for ad hoc disk files and a
good server-side database when an application server serializes requests.
That is almost exactly a single authoritative Godot master/world server.

The same SQLite docs also draw the boundary:

- SQLite reads and writes the database file directly; there is no separate DB
  server process.
- It supports many readers but only one writer at a time per database file.
- If many clients or many servers send SQL to the same database over a network,
  a client/server database is a better fit.

So SQLite is not overkill if the alternative is inventing your own query engine,
indexes, migrations, atomicity, and backups. But if your first persistence goal
is just "save account and character Resources owned by one master server",
SQLite can wait.

## SpacetimeDB Comparison

SpacetimeDB is useful because it validates the intuition that authoritative game
state can be RAM-first.

Official docs describe SpacetimeDB as a database that is also a server. Clients
connect directly to it, call reducers, and subscribe to realtime row updates.
It keeps application state in memory for speed and persists committed
transactions to a commit log. Reducers are the only way to mutate tables, and
each reducer runs in a database transaction. Subscriptions replicate matching
rows into a client-side cache.

Important distinction:

SpacetimeDB is not "just Resource files in RAM". It gives the RAM-first model a
transaction system, commit log, table/index model, reducer isolation, recovery,
and realtime subscription layer.

For a Godot MMO, SpacetimeDB may be attractive if you want to replace a large
part of the custom backend. It is less attractive as a small incremental storage
choice because official language support emphasizes Rust, C#, TypeScript, Unity,
and Unreal. I did not find an official Godot-specific happy path. Godot C# may
be possible, but it should be treated as an integration spike, not an assumption.

## Old 2D MMO Engine Evidence

The old engines are important because they show that simple file-backed MMO
storage was not imaginary. It worked because the runtime model was constrained:
one authoritative server, records kept in RAM, periodic saves, and modest CCU.

| Engine | Persistence shape | What it teaches |
|---|---|---|
| Eclipse Origins | VB6 binary files. Accounts under `server/data/accounts/<login>.bin`, banks under `server/data/banks/<login>.bin`, game data in `.dat`, config/classes in INI. The server loop periodically saves online players and banks every 5 minutes. | File-backed records are viable with one server and a simple save loop, but rollback windows and binary-struct migrations are real costs. |
| Mirage Source | Legacy VB6 lineage. Public downloads include classic flat-file-era releases and later variants that mention MySQL or SQLite. | The lineage moved from raw/binary storage toward databases as needs grew. |
| Elysium | VB6 2D MMORPG maker from the Mirage/Konfuze lineage. Public primary source evidence was weaker, but available docs place it in the same ecosystem. | Treat as lineage evidence, not strong proof of exact persistence internals. |
| XtremeWorlds | Legacy docs describe unloading unused maps/NPCs/objects/players from RAM and using fast binary file IO. The current open-source XtremeWorlds project is C#/FNA and uses PostgreSQL via `Npgsql` with JSONB rows. | The same idea modernized into a real database once the project became more serious. |
| Intersect Engine | Modern C#/MonoGame engine. Official docs describe separate game-data and player-data databases, Entity Framework contexts, migrations, and SQLite limitations. | Modern successors of the old engines chose relational persistence for tooling, migrations, and maintainability. |

Intersect is the cleanest contrast. Its docs say it has two databases: one for
game data such as items/maps/resources/events, and one for player accounts.
It uses Entity Framework-style contexts and migrations. The docs also call out
SQLite migration limitations, including one-way migrations and difficulty
renaming/removing fields.

That is the grown-up version of the old file approach: more setup, more schema
ceremony, but much better long-term data management.

## Resource Files Vs SQLite For One Master Server

| Question | Resource-backed object store | SQLite |
|---|---|---|
| Can one master own all writes? | Yes. This is the best case for Resources. | Yes. Also SQLite's best server-side shape. |
| Can all data stay in RAM? | Yes until memory or startup time becomes painful. | Yes as an app-level cache, while SQLite remains durable storage. |
| Can it scale beyond a prototype? | Yes if sharded into small files with dirty tracking, backups, migrations, and indexes. | Yes for a single shard/world with modest write volume. |
| Is it good for chat history? | Usually no. Append/query/history gets awkward fast. | Yes. Tiny MMO's chat store is exactly this. |
| Is it good for account records? | Yes for early scale if single-writer and sharded. | Yes, especially if auth/search/audit grows. |
| Is it good for guilds/social data? | Only while simple. Queries and indexes become custom code. | Better fit. |
| Is it easy to inspect in editor? | Yes, especially `.tres`. | Not inside Godot by default, but external tools are excellent. |
| Does it have transactions? | No, unless you build command batching and file replacement yourself. | Yes. |
| Does it have migrations? | Manual Resource versioning. | SQL/schema migrations. Still work, but standard. |
| Does it have backup tooling? | Manual. | Easier, and Tiny MMO already added backup rotation. |
| Does it avoid extra dependencies? | Yes. | Needs SQLite addon/native export handling, but no external DB service. |

## Practical Recommendation

For this multi-server spike:

- Do not add persistence yet.
- Keep learning from Tiny MMO, but do not import its SQLite layer into this MVP.

For the next persistence spike:

1. Start with a `DatabaseService` interface on the master server.
2. Implement a Resource-backed account/character store first.
3. Use sharded `.res` files, not one giant Resource.
4. Keep all live records in RAM.
5. Add dirty tracking, periodic save, logout save, graceful shutdown save, and
   temp-file replacement.
6. Benchmark load/save for 1,000, 10,000, and 100,000 character records.
7. Add crash-during-save tests.
8. Add a second backend that uses SQLite for the same account/character API.
9. Add SQLite immediately for chat history if persistent chat matters.

That gives you evidence instead of dogma. If Resource files handle the target
size and operational workflow, they are fine. If the tests reveal hitching,
corruption risk, migration pain, or query pain, SQLite is already the next
smallest step.

## Why Tiny MMO's Current World Data Fits SQLite

Based on source history, issue comments, and current schema, the safe conclusion
is not "Resources cannot work at all". The codebase now has data shapes where
SQLite helps:

- The project outgrew one object-shaped world database.
- It added player data, guilds, chat, block lists, flags, history, indexes, and
  migrations.
- SQLite made those features simpler than maintaining custom Resource indexes.
- The master account collection stayed Resource-backed because it is smaller
  and simpler.

That is a nuanced, useful result. Tiny MMO did not prove that Godot Resources are
worthless for persistence. It proved that Resources are a good minimal starting
point and that SQLite becomes appealing as soon as the data stops being a few
simple objects. The exact author intent behind the migration should still be
treated as an inference unless the maintainer documents it directly.

## Open Tests Before Choosing For A Real Mini-MMORPG

Run these before committing to Resource-only persistence:

- Load 1,000, 10,000, and 100,000 account/character Resource files at startup.
- Save 1,000 dirty character records and measure wall time.
- Save one giant Resource with the same data and compare hitching.
- Crash the process mid-save and verify recovery.
- Change a Resource schema and migrate old files.
- Rebuild indexes from records and verify uniqueness constraints.
- Simulate two login/create requests for the same username in one frame.
- Simulate a graceful shutdown, editor stop, process kill, and OS restart.
- Compare `.tres` and `.res` file size and save time.
- Repeat the same tests with SQLite.

## Source Links

- [Godot Tiny MMO repository](https://github.com/SlayHorizon/godot-tiny-mmo)
- [Godot Tiny MMO issue #45](https://github.com/SlayHorizon/godot-tiny-mmo/issues/45)
- [Godot Tiny MMO SQLite migration commit](https://github.com/SlayHorizon/godot-tiny-mmo/commit/6032c83e0cfde0c369043b884b7758d2d1739cab)
- [Godot Tiny MMO gh-pages home](https://raw.githubusercontent.com/SlayHorizon/godot-tiny-mmo/gh-pages/home.md)
- [Godot Tiny MMO next-level note](https://raw.githubusercontent.com/SlayHorizon/godot-tiny-mmo/gh-pages/pages/notes/next_level.md)
- [Current Tiny MMO authentication manager](https://raw.githubusercontent.com/SlayHorizon/godot-tiny-mmo/main/source/server/master/components/authentication_manager.gd)
- [Current Tiny MMO world database](https://raw.githubusercontent.com/SlayHorizon/godot-tiny-mmo/main/source/server/world/database/world_database.gd)
- [Current Tiny MMO world schema](https://raw.githubusercontent.com/SlayHorizon/godot-tiny-mmo/main/source/server/world/database/world_schema.gd)
- [Godot ResourceSaver docs](https://docs.godotengine.org/en/stable/classes/class_resourcesaver.html)
- [Godot ResourceLoader docs](https://docs.godotengine.org/en/stable/classes/class_resourceloader.html)
- [Godot data paths docs](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html)
- [SQLite appropriate uses](https://www.sqlite.org/whentouse.html)
- [SQLite isolation](https://www.sqlite.org/isolation.html)
- [SQLite serverless behavior](https://www.sqlite.org/serverless.html)
- [SpacetimeDB overview](https://spacetimedb.com/docs/intro/what-is-spacetimedb/)
- [SpacetimeDB FAQ](https://spacetimedb.com/docs/intro/faq/)
- [SpacetimeDB commit log](https://spacetimedb.com/docs/reference/internals/commitlog/)
- [SpacetimeDB reducers](https://spacetimedb.com/docs/functions/reducers/)
- [SpacetimeDB subscriptions](https://spacetimedb.com/docs/clients/subscriptions/)
- [SpacetimeDB language support](https://spacetimedb.com/docs/intro/language-support/)
- [Intersect database docs](https://docs.freemmorpgmaker.com/en-US/developer/advanced/database/)
- [Intersect Engine repository](https://github.com/AscensionGameDev/Intersect-Engine)
- [Eclipse Origins repository](https://github.com/RobinPerris/EclipseOrigins)
- [Mirage downloads](https://miragesource.net/downloads.php)
- [Elysium SourceForge](https://sourceforge.net/projects/elysium/)
- [Elysium lineage docs](https://elysiumnet.readthedocs.io/pt/latest/intro/overview.html)
- [XtremeWorlds site](https://xtremeworlds.com/)
- [XtremeWorlds ModDB page](https://www.moddb.com/engines/xtremeworlds)
- [Current XtremeWorlds database code](https://raw.githubusercontent.com/Treeflyx/XtremeWorlds/master/src/Server/Game/Database.cs)
