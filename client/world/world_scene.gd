extends Node2D

signal portal_requested(target_world: int)

const ICON := preload("res://icon.svg")
const PLAYER_SCENE := preload("res://client/player/Player.tscn")
const PORTAL_SCRIPT := preload("res://client/world/portal_area.gd")

@export var world_id := 1
@export var world_name := "World 1"
@export var world_color := Color(0.2, 0.8, 0.5, 1.0)
@export var portal_targets_csv := "2"

var available_world_ids: Array[int] = []

func _ready() -> void:
	_build_marker_field()
	_build_label()
	_build_player()
	_build_portals()


func set_available_world_ids(ids: Array[int]) -> void:
	available_world_ids = ids


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


func _build_player() -> void:
	var player := PLAYER_SCENE.instantiate()
	player.name = "Player"
	player.position = Vector2(320, 260)
	add_child(player)


func _build_portals() -> void:
	var targets := _portal_targets()
	for i in range(targets.size()):
		var target: int = targets[i]
		if not available_world_ids.is_empty() and not (target in available_world_ids):
			print("[CLIENT] hiding portal from world %d to unavailable world %d" % [world_id, target])
			continue

		var portal = PORTAL_SCRIPT.new()
		var color := Color(1.0, 0.85 - (0.25 * i), 0.15 + (0.35 * i), 1.0)
		portal.setup(target, color)
		portal.position = Vector2(180 + (i * 310), 420)
		portal.portal_entered.connect(func(target_world: int) -> void:
			portal_requested.emit(target_world)
		)
		add_child(portal)


func activate_portal_to(target_world: int) -> void:
	for child in get_children():
		if child is Area2D and child.get("target_world") == target_world:
			child.activate()
			return
	push_error("No portal from world %d to world %d" % [world_id, target_world])


func _portal_targets() -> Array[int]:
	var targets: Array[int] = []
	for raw_part in portal_targets_csv.split(",", false):
		var part := raw_part.strip_edges()
		if not part.is_empty():
			targets.append(int(part))
	return targets
