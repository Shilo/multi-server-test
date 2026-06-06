class_name PortalArea
extends Area2D

signal portal_entered(target_world: int)

const ICON := preload("res://icon.svg")
const PLAYER_COLLISION_LAYER := 2

var target_world := 1

func setup(new_target_world: int, portal_color: Color) -> void:
	target_world = new_target_world
	name = "PortalToWorld%d" % target_world
	collision_mask = 1 << (PLAYER_COLLISION_LAYER - 1)

	var sprite := Sprite2D.new()
	sprite.name = "Sprite2D"
	sprite.texture = ICON
	sprite.modulate = portal_color
	sprite.scale = Vector2(0.34, 0.34)
	add_child(sprite)

	var shape := CollisionShape2D.new()
	shape.name = "CollisionShape2D"
	var circle := CircleShape2D.new()
	circle.radius = 32.0
	shape.shape = circle
	add_child(shape)

	var label := Label.new()
	label.name = "Label"
	label.text = "To World %d" % target_world
	label.position = Vector2(-42, 38)
	add_child(label)

	body_entered.connect(_on_body_entered)


func activate() -> void:
	print("[CLIENT] portal entered: target_world=%d" % target_world)
	portal_entered.emit(target_world)


func _on_body_entered(body: Node) -> void:
	if body is CharacterBody2D and _is_local_authority_body(body):
		activate()


func _is_local_authority_body(body: Node) -> bool:
	if not body.multiplayer.has_multiplayer_peer():
		return true

	return body.is_multiplayer_authority()
