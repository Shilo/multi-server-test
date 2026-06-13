extends Node
## Master-owned SQLite access boundary.
##
## This is the ONLY place in the project that opens the SQLite database file.
## World servers never touch SQL; they report save commands to the master and
## the master commits them here. See docs/virtucade-database-mvp.md.

const ACCOUNT_REPOSITORY := preload("res://server/master/db/account_repository.gd")

## Database file path (godot-sqlite appends `default_extension`, default "db").
## Lives on the master's local disk under the Godot user data directory.
const DB_PATH := "user://virtucade"

## Migrations are embedded as plain statements instead of shipping `.sql` files,
## because Godot exports strip non-resource files by default and the master
## must be able to build its schema from inside the exported server binary.
## Each entry is { "version": int, "statements": Array[String] }.
const MIGRATIONS := [
	{
		"version": 1,
		"statements": [
			"""
			CREATE TABLE IF NOT EXISTS accounts (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				username TEXT NOT NULL,
				username_lower TEXT NOT NULL UNIQUE,
				world_key TEXT NOT NULL DEFAULT 'hub',
				pos_x REAL NOT NULL DEFAULT 0,
				pos_y REAL NOT NULL DEFAULT 0,
				has_position INTEGER NOT NULL DEFAULT 0,
				created_at INTEGER NOT NULL,
				updated_at INTEGER NOT NULL
			);
			""",
		],
	},
]

var _db: SQLite
var accounts


func _ready() -> void:
	_open()
	_migrate()
	accounts = ACCOUNT_REPOSITORY.new(self)
	print("MASTER_DB_READY path=%s" % _db.path)


func _exit_tree() -> void:
	if _db:
		_db.close_db()


func _open() -> void:
	_db = SQLite.new()
	_db.path = DB_PATH
	_db.foreign_keys = true
	# 0 = quiet, 1 = normal. Keep it quiet so per-query logs do not flood master.
	_db.verbosity_level = 0
	if not _db.open_db():
		push_error("[MASTER_DB] failed to open database: %s" % _db.error_message)
		return

	# Pragmas recommended by the database spike: WAL for concurrent reads while
	# the single master writer commits, a busy timeout so brief locks retry, and
	# NORMAL sync as a sane durability/throughput tradeoff for a game backend.
	_db.query("PRAGMA journal_mode = WAL;")
	_db.query("PRAGMA busy_timeout = 5000;")
	_db.query("PRAGMA synchronous = NORMAL;")


func _migrate() -> void:
	_db.query("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);")
	var applied := {}
	if _db.query("SELECT version FROM schema_migrations;"):
		for row in _db.query_result:
			applied[int(row["version"])] = true

	for migration in MIGRATIONS:
		var version := int(migration["version"])
		if applied.has(version):
			continue
		for statement in migration["statements"]:
			if not _db.query(statement):
				push_error("[MASTER_DB] migration %d failed: %s" % [version, _db.error_message])
				return
		_db.query_with_bindings(
			"INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?);",
			[version, int(Time.get_unix_time_from_system())]
		)
		print("MASTER_DB_MIGRATED version=%d" % version)


## Thin pass-throughs so repositories never hold the raw SQLite handle directly.

func run(sql: String, bindings: Array = []) -> bool:
	if bindings.is_empty():
		return _db.query(sql)
	return _db.query_with_bindings(sql, bindings)


func rows(sql: String, bindings: Array = []) -> Array:
	if not run(sql, bindings):
		push_error("[MASTER_DB] query failed: %s" % _db.error_message)
		return []
	return _db.query_result


func last_insert_rowid() -> int:
	return _db.last_insert_rowid
