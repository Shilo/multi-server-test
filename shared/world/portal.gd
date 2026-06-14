class_name Portal
extends Area2D

signal portal_used(portal_name: String, target_world: String)

const PLAYER_COLLISION_LAYER := 2
const ACTIVATION_COOLDOWN_SECONDS := 0.2

@export var target_world := ""
@export var target_portal := ""
@export var portal_color := Color(1.0, 0.75, 0.15, 1.0)

var local_body_inside := false
var can_activate_at := 0.0

@onready var sprite: Sprite2D = $Sprite2D
@onready var label: Label = $Label
@onready var prompt_label: Label = $PromptLabel


func _ready() -> void:
	collision_mask = 1 << (PLAYER_COLLISION_LAYER - 1)
	sprite.modulate = portal_color
	label.text = _display_label()
	prompt_label.visible = false
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _process(_delta: float) -> void:
	if not local_body_inside:
		return
	if Time.get_unix_time_from_system() < can_activate_at:
		return
	if Input.is_action_just_pressed("ui_accept"):
		activate()


func activate() -> void:
	NetLog.print_line("[CLIENT] portal use requested: portal=%s target_world=%s" % [name, target_world])
	portal_used.emit(str(name), target_world)


func _on_body_entered(body: Node) -> void:
	if not body is CharacterBody2D:
		return

	if _is_local_authority_body(body):
		local_body_inside = true
		can_activate_at = Time.get_unix_time_from_system() + ACTIVATION_COOLDOWN_SECONDS
		_update_prompt()


func _on_body_exited(body: Node) -> void:
	if not body is CharacterBody2D:
		return

	if _is_local_authority_body(body):
		local_body_inside = false
		_update_prompt()


func _display_label() -> String:
	return "To %s" % target_world.replace("_", " ").capitalize()


func _update_prompt() -> void:
	prompt_label.visible = local_body_inside


func _is_local_authority_body(body: Node) -> bool:
	if not body.multiplayer.has_multiplayer_peer():
		return true

	return body.is_multiplayer_authority()
