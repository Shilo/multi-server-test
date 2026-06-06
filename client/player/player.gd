extends CharacterBody2D

@export var speed := 180.0

func _physics_process(_delta: float) -> void:
	if multiplayer.has_multiplayer_peer() and not is_multiplayer_authority():
		velocity = Vector2.ZERO
		return

	var input_vector := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	velocity = input_vector * speed
	move_and_slide()
