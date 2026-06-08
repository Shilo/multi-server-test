extends Node


func _ready() -> void:
	if OS.has_feature("master_server") and OS.has_feature("world_server"):
		push_error("[MAIN] feature tag conflict: use only one of 'master_server' or 'world_server'")
		get_tree().quit(2)
		return

	if _load_scene("master_server"):
		return
	if _load_scene("world_server"):
		return
	_load_scene("client")


func _load_scene(name: String) -> bool:
	if name != "client" and not OS.has_feature(name):
		return false

	var scene_path := "res://%s/%s.tscn" % [name, name]
	var err := get_tree().change_scene_to_file(scene_path)
	if err != OK:
		push_error("[MAIN] failed to load role scene: %s err=%s" % [scene_path, err])
		get_tree().quit(3)
		return true

	print("[MAIN] role=%s scene=%s" % [name, scene_path])
	return true
