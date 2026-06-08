extends Node


func _ready() -> void:
	var user_args := OS.get_cmdline_user_args()
	if _is_server_build():
		if user_args.is_empty():
			_load_scene("master_server")
		else:
			_load_scene("world_server")
		return

	_load_scene("client")


func _is_server_build() -> bool:
	return OS.has_feature("server") or OS.has_feature("dedicated_server")


func _load_scene(name: String) -> void:
	var scene_path := "res://%s/%s.tscn" % [name, name]
	var err := get_tree().change_scene_to_file(scene_path)
	if err != OK:
		push_error("[MAIN] failed to load role scene: %s err=%s" % [scene_path, err])
		get_tree().quit(3)
		return

	print("[MAIN] role=%s scene=%s" % [name, scene_path])
