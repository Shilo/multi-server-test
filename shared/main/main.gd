extends Node

const CLIENT_SCENE := "res://client/client.tscn"
const MASTER_SCENE := "res://master_server/master_server.tscn"
const WORLD_SCENE := "res://world_server/world_server.tscn"


func _ready() -> void:
	var has_master_server := OS.has_feature("master_server")
	var has_world_server := OS.has_feature("world_server")

	if has_master_server and has_world_server:
		push_error("[MAIN] feature tag conflict: use only one of 'master_server' or 'world_server'")
		get_tree().quit(2)
		return

	var scene_path := CLIENT_SCENE
	var role := "client"
	if has_master_server:
		scene_path = MASTER_SCENE
		role = "master_server"
	elif has_world_server:
		scene_path = WORLD_SCENE
		role = "world_server"

	var scene := load(scene_path) as PackedScene
	if scene == null:
		push_error("[MAIN] failed to load role scene: %s" % scene_path)
		get_tree().quit(3)
		return

	add_child(scene.instantiate())
	print("[MAIN] role=%s scene=%s" % [role, scene_path])
