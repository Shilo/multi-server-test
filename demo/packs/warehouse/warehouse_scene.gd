extends Control

const _BOX_COUNT: int = 26
const _DEFAULT_SIZE: Vector2 = Vector2(900.0, 520.0)
const _FLOOR_HEIGHT: float = 34.0

@export var box_scene: PackedScene
@onready var _box_layer: Node2D = %BoxLayer
@onready var _floor_collision: CollisionShape2D = %FloorCollision
@onready var _left_wall_collision: CollisionShape2D = %LeftWallCollision
@onready var _right_wall_collision: CollisionShape2D = %RightWallCollision
@onready var _ceiling_collision: CollisionShape2D = %CeilingCollision


func _ready() -> void:
	clip_contents = true
	resized.connect(_layout_physics_world)
	_layout_physics_world()
	_spawn_boxes()


func _layout_physics_world() -> void:
	var bounds: Vector2 = size
	if bounds.x <= 0.0 or bounds.y <= 0.0:
		bounds = _DEFAULT_SIZE

	var floor_y: float = bounds.y - _FLOOR_HEIGHT
	_set_static_edge(_floor_collision, Vector2(0.0, floor_y), Vector2(bounds.x, floor_y))
	_set_static_edge(_left_wall_collision, Vector2(0.0, 0.0), Vector2(0.0, floor_y))
	_set_static_edge(_right_wall_collision, Vector2(bounds.x, 0.0), Vector2(bounds.x, floor_y))
	_set_static_edge(_ceiling_collision, Vector2(0.0, 0.0), Vector2(bounds.x, 0.0))


func _set_static_edge(collision: CollisionShape2D, point_a: Vector2, point_b: Vector2) -> void:
	if collision.shape is SegmentShape2D:
		var segment: SegmentShape2D = collision.shape
		segment.a = point_a
		segment.b = point_b


func _spawn_boxes() -> void:
	if box_scene == null:
		return

	var bounds: Vector2 = size
	if bounds.x <= 0.0 or bounds.y <= 0.0:
		bounds = _DEFAULT_SIZE

	for index in range(_BOX_COUNT):
		var instance: Node = box_scene.instantiate()
		if instance is not RigidBody2D:
			instance.queue_free()
			continue

		var box: RigidBody2D = instance
		box.name = "Box%02d" % index
		box.position = _initial_box_position(index, bounds)
		box.rotation = -0.38 + float((index * 17) % 76) / 100.0
		box.scale = Vector2.ONE * (0.88 + float((index * 5) % 18) / 100.0)
		_box_layer.add_child(box)

		var impulse: Vector2 = Vector2(-165.0 + float((index * 37) % 330), -155.0 - float((index * 19) % 130))
		box.apply_central_impulse(impulse)
		box.apply_torque_impulse(-260.0 + float((index * 29) % 520))


func _initial_box_position(index: int, bounds: Vector2) -> Vector2:
	var column: int = index % 9
	var row: int = floori(float(index) / 9.0)
	var usable_width: float = maxf(bounds.x - 140.0, 120.0)
	var x: float = 70.0 + float(column) * (usable_width / 8.0)
	var y: float = maxf(bounds.y - 190.0, 96.0) - float(row) * 42.0
	return Vector2(x, y)
