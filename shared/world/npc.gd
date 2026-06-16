extends CharacterBody2D

@export var npc_name := "Arcade NPC"
@export var npc_color := Color(1.0, 1.0, 1.0, 1.0)
@export var patrol_radius := Vector2(72.0, 28.0)
@export var patrol_speed := 1.0
@export var phase_offset := 0.0

var origin := Vector2.ZERO
var elapsed := 0.0

@onready var sprite: Sprite2D = $Sprite2D
@onready var label: Label = $Label


func _ready() -> void:
	origin = position
	sprite.modulate = npc_color
	label.text = npc_name


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	elapsed += delta * patrol_speed
	var t := elapsed + phase_offset
	position = origin + Vector2(cos(t) * patrol_radius.x, sin(t * 1.7) * patrol_radius.y)
