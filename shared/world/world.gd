extends Node2D

signal portal_requested(portal_name: String, target_world: String)

const PLAYER_SCENE := preload("res://shared/player/player.tscn")
const PORTAL_SCRIPT := preload("res://shared/world/portal.gd")
const SPAWN_SCRIPT := preload("res://shared/world/spawn.gd")
const SPAWN_ROOT_PATH := "SpawnRoot"
const SPAWNER_PATH := "MultiplayerSpawner"
const PORTAL_USE_DISTANCE := 72.0

var portals_by_name := {}


func _ready() -> void:
	var spawner := get_node(SPAWNER_PATH) as MultiplayerSpawner
	spawner.spawn_function = _spawn_player_from_data
	_cache_portals()


func spawn_player(peer_id: int, source_world := "", target_portal := "") -> Node:
	var spawn_root := get_node(SPAWN_ROOT_PATH)
	var player_name := "Player_%d" % peer_id
	if spawn_root.has_node(player_name):
		return spawn_root.get_node(player_name)

	var spawner := get_node(SPAWNER_PATH) as MultiplayerSpawner
	return spawner.spawn({
		"peer_id": peer_id,
		"position": spawn_position_from_entry(source_world, target_portal),
		"source_world": source_world,
		"target_portal": target_portal,
	})


func remove_player(peer_id: int) -> void:
	var spawn_root := get_node(SPAWN_ROOT_PATH)
	var player_name := "Player_%d" % peer_id
	if spawn_root.has_node(player_name):
		spawn_root.get_node(player_name).queue_free()


func activate_portal_to(target_world: String) -> void:
	var portal := _portal_for_target_world(target_world)
	if not portal:
		push_error("No portal from %s to %s" % [world_key(), target_world])
		return
	portal.activate()


func move_local_player_to_portal(target_world: String) -> bool:
	var portal := _portal_for_target_world(target_world)
	if not portal:
		return false

	var spawn_root := get_node(SPAWN_ROOT_PATH)
	for child in spawn_root.get_children():
		if child is CharacterBody2D and child.is_multiplayer_authority():
			child.position = portal.position
			return true
	return false


func player_can_use_portal(peer_id: int, portal_name: String) -> bool:
	var portal := portal_by_name(portal_name)
	if not portal:
		return false

	var spawn_root := get_node(SPAWN_ROOT_PATH)
	var player_name := "Player_%d" % peer_id
	if not spawn_root.has_node(player_name):
		return false

	var player := spawn_root.get_node(player_name) as Node2D
	return player.position.distance_to(portal.position) <= PORTAL_USE_DISTANCE


func portal_by_name(portal_name: String) -> Node2D:
	return portals_by_name.get(portal_name) as Node2D


func portal_target_world(portal_name: String) -> String:
	var portal := portal_by_name(portal_name)
	if not portal:
		return ""
	return str(portal.get("target_world"))


func portal_target_portal(portal_name: String) -> String:
	var portal := portal_by_name(portal_name)
	if not portal:
		return ""
	return str(portal.get("target_portal"))


func spawn_position_from_entry(source_world: String, target_portal: String) -> Vector2:
	if not target_portal.is_empty():
		var explicit_portal := portal_by_name(target_portal)
		if explicit_portal:
			return explicit_portal.position
		push_error("World %s has no target portal named %s" % [world_key(), target_portal])
		return Vector2.INF

	if not source_world.is_empty():
		var return_portals := _portals_targeting_world(source_world)
		if return_portals.size() == 1:
			return return_portals[0].position
		if return_portals.size() > 1:
			push_error("World %s has multiple portals targeting %s; set target_portal explicitly" % [world_key(), source_world])
			return Vector2.INF

	return _default_spawn_position()


func world_key() -> String:
	if not scene_file_path.is_empty():
		return scene_file_path.get_file().get_basename()
	return _snake_case(name)


func _spawn_player_from_data(data: Variant) -> Node:
	var spawn_data: Dictionary = {}
	if data is Dictionary:
		spawn_data = data

	var peer_id := int(spawn_data.get("peer_id", 1))
	var spawn_position: Vector2 = spawn_data.get("position", _default_spawn_position())
	var player := PLAYER_SCENE.instantiate()
	player.name = "Player_%d" % peer_id
	player.position = spawn_position
	player.set_multiplayer_authority(peer_id, true)
	return player


func _cache_portals() -> void:
	portals_by_name.clear()
	for portal in _all_portals():
		var portal_name := str(portal.name)
		if portals_by_name.has(portal_name):
			push_error("Duplicate portal name in %s: %s" % [world_key(), portal_name])
			continue
		if str(portal.get("target_world")).is_empty():
			push_warning("Portal %s in %s has no target_world" % [portal_name, world_key()])
		portals_by_name[portal_name] = portal
		portal.portal_used.connect(func(used_portal: String, target_world: String) -> void:
			portal_requested.emit(used_portal, target_world)
		)


func _all_portals() -> Array[Node2D]:
	var portals: Array[Node2D] = []
	_collect_portals(self, portals)
	return portals


func _collect_portals(node: Node, portals: Array[Node2D]) -> void:
	for child in node.get_children():
		if _is_portal(child):
			portals.append(child as Node2D)
		_collect_portals(child, portals)


func _portal_for_target_world(target_world: String) -> Node2D:
	for value in portals_by_name.values():
		var portal := value as Node2D
		if str(portal.get("target_world")) == target_world:
			return portal
	return null


func _portals_targeting_world(target_world: String) -> Array[Node2D]:
	var portals: Array[Node2D] = []
	for value in portals_by_name.values():
		var portal := value as Node2D
		if str(portal.get("target_world")) == target_world:
			portals.append(portal)
	return portals


func _default_spawn_position() -> Vector2:
	var spawn := _first_spawn(self)
	if spawn:
		return spawn.position
	return Vector2.ZERO


func _first_spawn(node: Node) -> Node2D:
	for child in node.get_children():
		if _is_spawn(child):
			return child as Node2D
		var nested_spawn := _first_spawn(child)
		if nested_spawn:
			return nested_spawn
	return null


func _is_portal(node: Node) -> bool:
	return node.get_script() == PORTAL_SCRIPT


func _is_spawn(node: Node) -> bool:
	return node.get_script() == SPAWN_SCRIPT


func _snake_case(value: String) -> String:
	var result := ""
	for index in range(value.length()):
		var character := value.substr(index, 1)
		if index > 0 and _is_uppercase_letter(character):
			result += "_"
		result += character.to_lower()
	return result


func _is_uppercase_letter(character: String) -> bool:
	return character >= "A" and character <= "Z"
