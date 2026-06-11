class_name PackRatJsonCacheStore
extends PackRatCacheStore

var cache_dir: String = "user://pack_rat"
var data: Dictionary = {
	"schema": 1,
	"items": {},
}


func configure(cache_dir_value: String) -> void:
	cache_dir = cache_dir_value


func load_cache() -> void:
	_ensure_directory(cache_dir)

	var path := _cache_path()
	if not FileAccess.file_exists(path):
		data = {
			"schema": 1,
			"items": {},
		}
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("PackRat could not open cache file %s (error %d)." % [path, FileAccess.get_open_error()])
		return

	var parsed := JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		data = parsed

	if not data.has("items") or not (data["items"] is Dictionary):
		data["items"] = {}


func get_record(cache_key: String) -> Dictionary:
	load_cache()
	return data["items"].get(cache_key, {})


func set_record(cache_key: String, record: Dictionary) -> void:
	load_cache()
	data["items"][cache_key] = record


func save() -> Error:
	_ensure_directory(cache_dir)

	var path := _cache_path()
	var temp_path := "%s.tmp" % path
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()

	file.store_string(JSON.stringify(data, "\t"))
	file = null
	return DirAccess.rename_absolute(temp_path, path)


func _cache_path() -> String:
	return cache_dir.path_join("cache.json")


func _ensure_directory(path: String) -> void:
	var error := DirAccess.make_dir_recursive_absolute(path)
	if error != OK and error != ERR_ALREADY_EXISTS:
		push_warning("PackRat could not create directory %s (error %d)." % [path, error])
