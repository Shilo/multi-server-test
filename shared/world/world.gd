extends Node2D

signal portal_requested(target_world: String)

const ICON := preload("res://icon.svg")
const PLAYER_SCENE := preload("res://shared/player/player.tscn")
const PORTAL_SCRIPT := preload("res://shared/world/portal_area.gd")
const SPAWN_ROOT_PATH := "SpawnRoot"
const SPAWNER_PATH := "MultiplayerSpawner"

@export var world_key := "hub"
@export var world_name := "Hub"
@export var world_color := Color(0.2, 0.8, 0.5, 1.0)
@export var portal_targets_csv := "left_world"
@export var player_spawn_position := Vector2(400, 260)

var available_world_keys: Array[String] = []
var portal_positions := {}


func _ready() -> void:
	var spawner := get_node(SPAWNER_PATH) as MultiplayerSpawner
	spawner.spawn_function = _spawn_player_from_data
	_build_marker_field()
	_build_label()
	_build_portals()


func set_available_world_keys(keys: Array[String]) -> void:
	available_world_keys = keys


func _build_marker_field() -> void:
	for i in range(5):
		var marker := Sprite2D.new()
		marker.name = "WorldMarker%d" % i
		marker.texture = ICON
		marker.modulate = world_color
		marker.modulate.a = 0.35
		marker.scale = Vector2(0.65 + (i * 0.08), 0.65 + (i * 0.08))
		marker.position = Vector2(95 + (i * 118), 110 + ((i % 2) * 190))
		add_child(marker)


func _build_label() -> void:
	var label := Label.new()
	label.name = "WorldLabel"
	label.text = "%s  |  Portals: %s" % [world_name, portal_targets_csv]
	label.position = Vector2(24, 54)
	add_child(label)


func spawn_player(peer_id: int, source_world := "") -> Node:
	var spawn_root := get_node(SPAWN_ROOT_PATH)
	var player_name := "Player_%d" % peer_id
	if spawn_root.has_node(player_name):
		return spawn_root.get_node(player_name)

	var spawner := get_node(SPAWNER_PATH) as MultiplayerSpawner
	return spawner.spawn({
		"peer_id": peer_id,
		"position": spawn_position_from_source(source_world),
		"source_world": source_world,
	})


func _spawn_player_from_data(data: Variant) -> Node:
	var spawn_data: Dictionary = {}
	if data is Dictionary:
		spawn_data = data

	var peer_id := int(spawn_data.get("peer_id", 1))
	var spawn_position: Vector2 = spawn_data.get("position", player_spawn_position)
	var player := PLAYER_SCENE.instantiate()
	player.name = "Player_%d" % peer_id
	player.position = spawn_position
	player.set_multiplayer_authority(peer_id, true)
	return player


func remove_player(peer_id: int) -> void:
	var spawn_root := get_node(SPAWN_ROOT_PATH)
	var player_name := "Player_%d" % peer_id
	if spawn_root.has_node(player_name):
		spawn_root.get_node(player_name).queue_free()


func _build_portals() -> void:
	portal_positions.clear()
	var targets := _portal_targets()
	for i in range(targets.size()):
		var target := str(targets[i])
		if not available_world_keys.is_empty() and not (target in available_world_keys):
			print("[CLIENT] hiding portal from %s to unavailable %s" % [world_key, target])
			continue

		var portal = PORTAL_SCRIPT.new()
		var color := Color(1.0, 0.85 - (0.25 * i), 0.15 + (0.35 * i), 1.0)
		portal.setup(target, color)
		portal.position = _portal_position(target, i, targets.size())
		portal_positions[target] = portal.position
		portal.portal_entered.connect(func(target_world: String) -> void:
			portal_requested.emit(target_world)
		)
		add_child(portal)


func activate_portal_to(target_world: String) -> void:
	for child in get_children():
		if child is Area2D and child.get("target_world") == target_world:
			child.activate()
			return
	push_error("No portal from %s to %s" % [world_key, target_world])


func move_local_player_to_portal(target_world: String) -> bool:
	if not portal_positions.has(target_world):
		return false

	var spawn_root := get_node(SPAWN_ROOT_PATH)
	for child in spawn_root.get_children():
		if child is CharacterBody2D and child.is_multiplayer_authority():
			child.position = portal_positions[target_world]
			return true
	return false


func player_can_use_portal(peer_id: int, target_world: String) -> bool:
	if not portal_positions.has(target_world):
		return false

	var spawn_root := get_node(SPAWN_ROOT_PATH)
	var player_name := "Player_%d" % peer_id
	if not spawn_root.has_node(player_name):
		return false

	var player := spawn_root.get_node(player_name) as Node2D
	var portal_position: Vector2 = portal_positions[target_world]
	return player.position.distance_to(portal_position) <= 72.0


func spawn_position_from_source(source_world: String) -> Vector2:
	if source_world.is_empty() or not portal_positions.has(source_world):
		return player_spawn_position

	var portal_position: Vector2 = portal_positions[source_world]
	var away_from_portal := player_spawn_position - portal_position
	if away_from_portal.length() < 1.0:
		away_from_portal = Vector2.DOWN
	return portal_position + away_from_portal.normalized() * 84.0


func _portal_targets() -> Array[String]:
	var targets: Array[String] = []
	for raw_part in portal_targets_csv.split(",", false):
		var part := raw_part.strip_edges()
		if not part.is_empty():
			targets.append(part)
	return targets


func _portal_position(target_world: String, index: int, count: int) -> Vector2:
	if world_key == "hub":
		match target_world:
			"left_world":
				return Vector2(170, 260)
			"right_world":
				return Vector2(630, 260)
			"top_world":
				return Vector2(400, 130)

	if target_world == "hub":
		match world_key:
			"left_world":
				return Vector2(630, 260)
			"right_world":
				return Vector2(170, 260)
			"top_world":
				return Vector2(400, 410)

	var spacing := 560.0 / float(max(count, 1))
	return Vector2(120 + (spacing * (index + 0.5)), 400)
