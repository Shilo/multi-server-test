extends CharacterBody2D

const LOCAL_CAMERA_NAME := "LocalAuthorityCamera"

@export var speed := 180.0

func _enter_tree() -> void:
	_apply_authority_from_name()


func _ready() -> void:
	_apply_authority_from_name()
	_apply_authority_from_name.call_deferred()
	_update_local_camera.call_deferred()


func _apply_authority_from_name() -> void:
	if not name.begins_with("Player_"):
		return

	var peer_id := int(name.trim_prefix("Player_"))
	if peer_id > 0:
		set_multiplayer_authority(peer_id, true)


func _physics_process(_delta: float) -> void:
	_apply_authority_from_name()
	_update_local_camera()
	if multiplayer.has_multiplayer_peer() and not is_multiplayer_authority():
		velocity = Vector2.ZERO
		return

	var input_vector := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	velocity = input_vector * speed
	move_and_slide()


func _update_local_camera() -> void:
	var is_local_player := not multiplayer.has_multiplayer_peer() or is_multiplayer_authority()
	var camera := get_node_or_null(LOCAL_CAMERA_NAME) as Camera2D
	if camera == null and is_local_player:
		camera = Camera2D.new()
		camera.name = LOCAL_CAMERA_NAME
		camera.position = Vector2.ZERO
		add_child(camera)

	if camera == null:
		return

	camera.enabled = is_local_player
	if is_local_player and not camera.is_current():
		camera.make_current()
