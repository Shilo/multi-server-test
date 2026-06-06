extends CharacterBody2D

@export var speed := 180.0

func _enter_tree() -> void:
	_apply_authority_from_name()


func _ready() -> void:
	_apply_authority_from_name()
	_apply_authority_from_name.call_deferred()


func _apply_authority_from_name() -> void:
	if not name.begins_with("Player_"):
		return

	var peer_id := int(name.trim_prefix("Player_"))
	if peer_id > 0:
		set_multiplayer_authority(peer_id, true)


func _physics_process(_delta: float) -> void:
	_apply_authority_from_name()
	if multiplayer.has_multiplayer_peer() and not is_multiplayer_authority():
		velocity = Vector2.ZERO
		return

	var input_vector := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	velocity = input_vector * speed
	move_and_slide()
