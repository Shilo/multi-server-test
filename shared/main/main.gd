extends Node

const CLIENT_SCENE := "res://client/client.tscn"
const MASTER_SCENE := "res://server/master/master.tscn"
const WORLD_SCENE := "res://server/world/world.tscn"


func _ready() -> void:
	var scene_path := CLIENT_SCENE
	var user_args := OS.get_cmdline_user_args()
	if _is_server_build():
		if user_args.is_empty():
			scene_path = MASTER_SCENE
		else:
			scene_path = WORLD_SCENE

	call_deferred("_change_scene", scene_path)


func _change_scene(scene_path: String) -> void:
	var err := get_tree().change_scene_to_file(scene_path)
	if err != OK:
		push_error("[MAIN] failed to load scene: %s err=%s" % [scene_path, err])
		get_tree().quit(3)


func _is_server_build() -> bool:
	return OS.has_feature("server") or OS.has_feature("dedicated_server")
