class_name PortalArea
extends Area2D

signal portal_entered(target_world: String)

const ICON := preload("res://icon.svg")
const PLAYER_COLLISION_LAYER := 2

var target_world := "hub"
var local_body_inside := false
var prompt_label: Label


func setup(new_target_world: String, portal_color: Color) -> void:
	target_world = new_target_world
	name = "PortalTo%s" % _pascal_case(new_target_world)
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
	label.text = "To %s" % new_target_world.replace("_", " ").capitalize()
	label.position = Vector2(-42, 38)
	add_child(label)

	prompt_label = Label.new()
	prompt_label.name = "PromptLabel"
	prompt_label.text = "[SPACE]"
	prompt_label.position = Vector2(-34, -58)
	prompt_label.visible = false
	add_child(prompt_label)

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _process(_delta: float) -> void:
	if local_body_inside and Input.is_action_just_pressed("ui_accept"):
		activate()


func activate() -> void:
	print("[CLIENT] portal use requested: target_world=%s" % target_world)
	portal_entered.emit(target_world)


func _on_body_entered(body: Node) -> void:
	if not body is CharacterBody2D:
		return

	if _is_local_authority_body(body):
		local_body_inside = true
		_update_prompt()


func _on_body_exited(body: Node) -> void:
	if not body is CharacterBody2D:
		return

	if _is_local_authority_body(body):
		local_body_inside = false
		_update_prompt()


func _update_prompt() -> void:
	if prompt_label:
		prompt_label.visible = local_body_inside


func _is_local_authority_body(body: Node) -> bool:
	if not body.multiplayer.has_multiplayer_peer():
		return true

	return body.is_multiplayer_authority()


func _pascal_case(value: String) -> String:
	var result := ""
	for part in value.split("_", false):
		result += part.capitalize()
	return result
