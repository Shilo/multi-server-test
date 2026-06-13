extends RefCounted
## Account persistence for the fake (name-only) login system.
##
## "Login" is name-only by design (no passwords; proper auth is out of scope for
## this MVP). Usernames are unique case-insensitively via `username_lower`.

const MAX_USERNAME_LENGTH := 20

var _db


func _init(database_service) -> void:
	_db = database_service


## Returns a sanitized username or "" if the input is not acceptable.
static func sanitize_username(raw: String) -> String:
	var name := raw.strip_edges()
	if name.length() > MAX_USERNAME_LENGTH:
		name = name.left(MAX_USERNAME_LENGTH).strip_edges()
	if name.is_empty():
		return ""
	# Disallow names that look like auto-generated guest handles to avoid
	# impersonation of the guest namespace.
	if name.to_lower().begins_with("guest-"):
		return ""
	return name


func find_by_username(username: String) -> Dictionary:
	var rows: Array = _db.rows(
		"SELECT * FROM accounts WHERE username_lower = ? LIMIT 1;",
		[username.to_lower()]
	)
	if rows.is_empty():
		return {}
	return rows[0]


## Returns the account row for `username`, creating it on first use.
## Result keys: id, username, world_key, pos_x, pos_y, has_position.
func get_or_create(username: String) -> Dictionary:
	var existing := find_by_username(username)
	if not existing.is_empty():
		return existing

	var now := int(Time.get_unix_time_from_system())
	var ok: bool = _db.run(
		"INSERT INTO accounts (username, username_lower, world_key, pos_x, pos_y, has_position, created_at, updated_at) VALUES (?, ?, 'hub', 0, 0, 0, ?, ?);",
		[username, username.to_lower(), now, now]
	)
	if not ok:
		# Most likely a UNIQUE collision from a concurrent create; re-read.
		return find_by_username(username)
	return find_by_username(username)


func update_position(account_id: int, world_key: String, pos_x: float, pos_y: float) -> void:
	_db.run(
		"UPDATE accounts SET world_key = ?, pos_x = ?, pos_y = ?, has_position = 1, updated_at = ? WHERE id = ?;",
		[world_key, pos_x, pos_y, int(Time.get_unix_time_from_system()), account_id]
	)
