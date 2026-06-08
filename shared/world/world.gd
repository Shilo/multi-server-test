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


func spawn_player(peer_id: int) -> Node:
	var spawn_root := get_node(SPAWN_ROOT_PATH)
	var player_name := "Player_%d" % peer_id
	if spawn_root.has_node(player_name):
		return spawn_root.get_node(player_name)

	var spawner := get_node(SPAWNER_PATH) as MultiplayerSpawner
	return spawner.spawn({
		"peer_id": peer_id,
		"position": player_spawn_position,
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
	var targets := _portal_targets()
	for i in range(targets.size()):
		var target := str(targets[i])
		if not available_world_keys.is_empty() and not (target in available_world_keys):
			print("[CLIENT] hiding portal from %s to unavailable %s" % [world_key, target])
			continue

		var portal = PORTAL_SCRIPT.new()
		var color := Color(1.0, 0.85 - (0.25 * i), 0.15 + (0.35 * i), 1.0)
		portal.setup(target, color)
		portal.position = Vector2(180 + (i * 310), 420)
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


func _portal_targets() -> Array[String]:
	var targets: Array[String] = []
	for raw_part in portal_targets_csv.split(",", false):
		var part := raw_part.strip_edges()
		if not part.is_empty():
			targets.append(part)
	return targets
