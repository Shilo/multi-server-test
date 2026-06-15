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
	if not _open():
		get_tree().quit(20)
		return
	if not _migrate():
		get_tree().quit(21)
		return
	accounts = ACCOUNT_REPOSITORY.new(self)
	NetLog.print_line("MASTER_DB_READY path=%s" % _db.path)


func _exit_tree() -> void:
	if _db:
		_db.close_db()


func _open() -> bool:
	_db = SQLite.new()
	_db.path = DB_PATH
	_db.foreign_keys = true
	# 0 = quiet, 1 = normal. Keep it quiet so per-query logs do not flood master.
	_db.verbosity_level = 0
	if not _db.open_db():
		push_error("[MASTER_DB] failed to open database: %s" % _db.error_message)
		return false

	# Pragmas recommended by the database spike: WAL for concurrent reads while
	# the single master writer commits, a busy timeout so brief locks retry, and
	# NORMAL sync as a sane durability/throughput tradeoff for a game backend.
	return (
		_query_startup("PRAGMA journal_mode = WAL;")
		and _query_startup("PRAGMA busy_timeout = 5000;")
		and _query_startup("PRAGMA synchronous = NORMAL;")
	)


func _migrate() -> bool:
	if not _query_startup("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);"):
		return false
	var applied := {}
	if _db.query("SELECT version FROM schema_migrations;"):
		for row in _db.query_result:
			applied[int(row["version"])] = true
	else:
		push_error("[MASTER_DB] could not read schema migrations: %s" % _db.error_message)
		return false

	for migration in MIGRATIONS:
		var version := int(migration["version"])
		if applied.has(version):
			continue
		if not _query_startup("BEGIN TRANSACTION;"):
			return false
		for statement in migration["statements"]:
			if not _db.query(statement):
				push_error("[MASTER_DB] migration %d failed: %s" % [version, _db.error_message])
				_db.query("ROLLBACK;")
				return false
		if not _db.query_with_bindings(
			"INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?);",
			[version, int(Time.get_unix_time_from_system())]
		):
			push_error("[MASTER_DB] migration %d marker failed: %s" % [version, _db.error_message])
			_db.query("ROLLBACK;")
			return false
		if not _query_startup("COMMIT;"):
			_db.query("ROLLBACK;")
			return false
		NetLog.print_line("MASTER_DB_MIGRATED version=%d" % version)
	return true


func _query_startup(sql: String) -> bool:
	if _db.query(sql):
		return true
	push_error("[MASTER_DB] startup query failed: %s sql=%s" % [_db.error_message, sql])
	return false


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
