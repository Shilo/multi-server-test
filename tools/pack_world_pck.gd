extends SceneTree

const WORLD_ROOT := "res://server/worlds"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		_fail("usage: godot --headless --path <project> -s res://tools/pack_world_pck.gd -- <world_key> <output.pck>")
		return

	var world_key := str(args[0])
	var output_path := str(args[1])
	var world_dir := "%s/%s" % [WORLD_ROOT, world_key]
	var scene_path := "%s/%s.tscn" % [world_dir, world_key]
	if not ResourceLoader.exists(scene_path, "PackedScene"):
		_fail("world scene does not exist: %s" % scene_path)
		return

	var output_dir := output_path.get_base_dir()
	if not output_dir.is_empty():
		var dir_err := DirAccess.make_dir_recursive_absolute(output_dir)
		if dir_err != OK:
			_fail("failed to create output directory %s err=%s" % [output_dir, dir_err])
			return

	var packer := PCKPacker.new()
	var err := packer.pck_start(output_path)
	if err != OK:
		_fail("failed to start PCK %s err=%s" % [output_path, err])
		return

	var files: Array[String] = []
	if not _collect_files(world_dir, files):
		return
	files.sort()

	for res_path in files:
		var source_path := ProjectSettings.globalize_path(res_path)
		err = packer.add_file(res_path, source_path)
		if err != OK:
			_fail("failed to add %s err=%s" % [res_path, err])
			return

	err = packer.flush(true)
	if err != OK:
		_fail("failed to flush PCK %s err=%s" % [output_path, err])
		return

	print("WORLD_PACK_PCK_DONE world=%s output=%s files=%d" % [world_key, output_path, files.size()])
	quit(0)


func _collect_files(res_dir: String, files: Array[String]) -> bool:
	var dir := DirAccess.open(res_dir)
	if dir == null:
		_fail("failed to open world directory: %s" % res_dir)
		return false

	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry.begins_with("."):
			entry = dir.get_next()
			continue

		var child_path := "%s/%s" % [res_dir, entry]
		if dir.current_is_dir():
			if not _collect_files(child_path, files):
				return false
		elif _should_pack_file(entry):
			files.append(child_path)
		entry = dir.get_next()
	dir.list_dir_end()
	return true


func _should_pack_file(file_name: String) -> bool:
	return not file_name.ends_with(".import")


func _fail(message: String) -> void:
	push_error("[PACK_WORLD] %s" % message)
	quit(1)
