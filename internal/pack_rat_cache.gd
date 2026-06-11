class_name PackRatCache extends RefCounted
## Internal [code]cache.json[/code] wrapper used by [PackRat].

const _SCHEMA: int = 1

var _cache_dir: String = ""
var _items: Dictionary = {}


## Loads cache metadata from [param cache_dir].
static func load(cache_dir: String) -> PackRatCache:
	var cache: PackRatCache = PackRatCache.new()
	cache._cache_dir = cache_dir

	var path: String = cache._path()
	if not FileAccess.file_exists(path):
		return cache

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return cache

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary and parsed.has("items") and (parsed["items"] is Dictionary):
		cache._items = parsed["items"]

	return cache


## Returns the cache record stored at [param key], or an empty record.
func record(key: String) -> PackRatCacheRecord:
	return PackRatCacheRecord.from_dictionary(_items.get(key, {}))


## Stores [param record] at [param key].
func set_record(key: String, record: PackRatCacheRecord) -> void:
	_items[key] = record.to_dictionary()


## Saves cache metadata to [code]cache.json[/code].
func save() -> Error:
	var path: String = _path()
	var part_path: String = "%s.tmp" % path
	var file: FileAccess = FileAccess.open(part_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()

	file.store_string(JSON.stringify({"schema": _SCHEMA, "items": _items}, "\t"))
	file = null

	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

	return DirAccess.rename_absolute(part_path, path)


func _path() -> String:
	return _cache_dir.path_join("cache.json")
