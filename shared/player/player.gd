extends CharacterBody2D

@export var speed := 180.0

## Identity baked into spawn data by the world server and replicated to every
## peer. Guests render as semi-transparent "ghosts"; the name label is shown
## only above remote players.
var display_name := ""
var is_guest := true

var authority_applied := false

@onready var sprite: Sprite2D = $Sprite2D
@onready var name_label: Label = $NameLabel


func _enter_tree() -> void:
	_apply_authority_from_name()


func _ready() -> void:
	_apply_authority_from_name()
	_apply_authority_from_name.call_deferred()
	_apply_identity_visuals()


func _apply_authority_from_name() -> void:
	if authority_applied:
		return
	if not name.begins_with("Player_"):
		return

	var peer_id := int(name.trim_prefix("Player_"))
	if peer_id > 0:
		set_multiplayer_authority(peer_id, true)
		authority_applied = true
		_update_name_label_visibility()


func _apply_identity_visuals() -> void:
	if name_label:
		name_label.text = display_name
	# Ghost only the sprite so the name label stays fully readable.
	if sprite:
		sprite.modulate.a = 0.45 if is_guest else 1.0
	_update_name_label_visibility()


func _update_name_label_visibility() -> void:
	if not name_label:
		return
	var is_remote := multiplayer.has_multiplayer_peer() and not is_multiplayer_authority()
	name_label.visible = is_remote and not display_name.is_empty()


func _physics_process(_delta: float) -> void:
	_apply_authority_from_name()
	if multiplayer.has_multiplayer_peer() and not is_multiplayer_authority():
		velocity = Vector2.ZERO
		return

	var input_vector := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	velocity = input_vector * speed
	move_and_slide()
