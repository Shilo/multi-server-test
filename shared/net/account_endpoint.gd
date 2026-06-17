extends Node
## Identity / session control plane, hosted on MasterNet alongside MasterEndpoint
## and ChatEndpoint. The master is the only process that owns sessions and the
## only process that talks to the database.
##
## Every version-validated client gets a guest session. A name-only "login" (no
## password — proper auth is out of scope for this MVP) promotes the session to
## an account, loading its saved world + position. Logout reverts to a fresh
## guest. See docs/virtucade-database-mvp.md.

# Client-side signals.
signal session_updated(display_name: String, is_guest: bool, account_id: int)
signal resume_world_requested(world_key: String, endpoint: Dictionary)
signal login_failed(reason: String)

const NET_CONFIG := preload("res://shared/net/net_config.gd")
const NET_UTIL := preload("res://shared/net/net_util.gd")

# Server-only state.
var database_service: Node
var master_endpoint: Node
var sessions := {}
var _guest_counter := 0


func configure(database: Node, master: Node) -> void:
	database_service = database
	master_endpoint = master


# ---------------------------------------------------------------------------
# Server: session lifecycle (called by master.gd on peer connect/disconnect)
# ---------------------------------------------------------------------------

func create_guest_session(peer_id: int) -> void:
	if sessions.has(peer_id):
		return
	_guest_counter += 1
	var session := {
		"account_id": 0,
		"display_name": "Guest-%d" % _guest_counter,
		"is_guest": true,
		"active_world_key": "",
	}
	sessions[peer_id] = session
	_push_session(peer_id)


func drop_session(peer_id: int) -> void:
	sessions.erase(peer_id)


## Identity the world should bake into the player's spawn data. The active world
## is committed only after the target world confirms the join ticket was used.
func get_join_identity(peer_id: int, _world_key: String) -> Dictionary:
	var session: Dictionary = sessions.get(peer_id, {})
	if session.is_empty():
		return {"display_name": "Player_%d" % peer_id, "is_guest": true}

	return {
		"display_name": str(session["display_name"]),
		"is_guest": bool(session["is_guest"]),
	}


func commit_active_world(peer_id: int, world_key: String) -> void:
	if not NET_CONFIG.is_valid_world_key(world_key):
		return
	var session: Dictionary = sessions.get(peer_id, {})
	if session.is_empty():
		return
	session["active_world_key"] = world_key
	sessions[peer_id] = session


func session_display_name(peer_id: int) -> String:
	var session: Dictionary = sessions.get(peer_id, {})
	return str(session.get("display_name", "Guest"))


## Commit a position reported by a world server. Guests are skipped, and the
## save must come from the world the master currently believes the player is in.
func save_position(peer_id: int, world_key: String, pos_x: float, pos_y: float) -> void:
	var session: Dictionary = sessions.get(peer_id, {})
	if session.is_empty() or bool(session.get("is_guest", true)):
		return
	if str(session.get("active_world_key", "")) != world_key:
		return
	var account_id := int(session.get("account_id", 0))
	if account_id <= 0:
		return
	database_service.accounts.update_position(account_id, world_key, pos_x, pos_y)


# ---------------------------------------------------------------------------
# Server: RPCs from clients
# ---------------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func login(raw_username: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not _is_validated_client_peer(sender_id):
		_reject_unvalidated_client_peer(sender_id, "login")
		return
	if not sessions.has(sender_id):
		return

	var account_repository = database_service.accounts
	var username: String = account_repository.sanitize_username(raw_username)
	if username.is_empty():
		if _is_peer_open(sender_id):
			push_login_error.rpc_id(sender_id, "Enter 1-20 characters (the 'Guest-' prefix is reserved).")
		return

	var account: Dictionary = account_repository.get_or_create(username)
	if account.is_empty():
		if _is_peer_open(sender_id):
			push_login_error.rpc_id(sender_id, "Could not load that account, try again.")
		return

	var world_key := str(account.get("world_key", NET_CONFIG.initial_world()))
	if not NET_CONFIG.is_valid_world_key(world_key):
		world_key = NET_CONFIG.initial_world()

	var session: Dictionary = sessions[sender_id]
	session["account_id"] = int(account["id"])
	session["display_name"] = str(account["username"])
	session["is_guest"] = false
	sessions[sender_id] = session

	var has_position := int(account.get("has_position", 0)) == 1
	var endpoint := _create_resume_lease(sender_id, world_key, has_position, float(account.get("pos_x", 0.0)), float(account.get("pos_y", 0.0)))

	NetLog.print_line("MASTER_LOGIN peer=%d account=%d world=%s" % [sender_id, int(account["id"]), world_key])
	_push_session(sender_id)
	if _is_peer_open(sender_id):
		push_resume_world.rpc_id(sender_id, world_key, endpoint)


@rpc("any_peer", "call_remote", "reliable")
func logout() -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not _is_validated_client_peer(sender_id):
		_reject_unvalidated_client_peer(sender_id, "logout")
		return
	if not sessions.has(sender_id) or bool(sessions[sender_id].get("is_guest", true)):
		return

	var hub := NET_CONFIG.initial_world()
	_guest_counter += 1
	var session: Dictionary = sessions[sender_id]
	session["account_id"] = 0
	session["display_name"] = "Guest-%d" % _guest_counter
	session["is_guest"] = true
	sessions[sender_id] = session

	var endpoint := _create_resume_lease(sender_id, hub, false, 0.0, 0.0)
	NetLog.print_line("MASTER_LOGOUT peer=%d" % sender_id)
	_push_session(sender_id)
	if _is_peer_open(sender_id):
		push_resume_world.rpc_id(sender_id, hub, endpoint)


func _create_resume_lease(peer_id: int, world_key: String, has_spawn: bool, spawn_x: float, spawn_y: float) -> Dictionary:
	if master_endpoint and master_endpoint.has_method("create_login_resume_lease"):
		return master_endpoint.create_login_resume_lease(peer_id, world_key, has_spawn, spawn_x, spawn_y)
	return {}


func _push_session(peer_id: int) -> void:
	var session: Dictionary = sessions.get(peer_id, {})
	if session.is_empty():
		return
	if not _is_peer_open(peer_id):
		return
	push_session.rpc_id(
		peer_id,
		str(session["display_name"]),
		bool(session["is_guest"]),
		int(session["account_id"])
	)


func _is_validated_client_peer(peer_id: int) -> bool:
	if not master_endpoint or not master_endpoint.has_method("is_validated_client_peer"):
		return false
	return master_endpoint.is_validated_client_peer(peer_id)


func _reject_unvalidated_client_peer(peer_id: int, rpc_name: String) -> void:
	if master_endpoint and master_endpoint.has_method("reject_unvalidated_client_peer"):
		master_endpoint.reject_unvalidated_client_peer(peer_id, rpc_name)


func _is_peer_open(peer_id: int) -> bool:
	return NET_UTIL.is_peer_open(multiplayer, peer_id)


# ---------------------------------------------------------------------------
# Client: RPCs from master
# ---------------------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func push_session(display_name: String, is_guest: bool, account_id: int) -> void:
	if multiplayer.is_server():
		return
	session_updated.emit(display_name, is_guest, account_id)


@rpc("authority", "call_remote", "reliable")
func push_resume_world(world_key: String, endpoint: Dictionary) -> void:
	if multiplayer.is_server():
		return
	resume_world_requested.emit(world_key, endpoint)


@rpc("authority", "call_remote", "reliable")
func push_login_error(reason: String) -> void:
	if multiplayer.is_server():
		return
	login_failed.emit(reason)
