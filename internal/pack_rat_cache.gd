class_name PackRatCache extends RefCounted
## Internal [code]cache.json[/code] wrapper used by [PackRat].

const _SCHEMA: int = 1

var _cache_dir: String = ""
var _items: Dictionary = {}
var _removed_keys: PackedStringArray = []


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
	_removed_keys.erase(key)


## Removes the cache record at [param key].
func erase_record(key: String) -> void:
	_items.erase(key)
	if not _removed_keys.has(key):
		_removed_keys.append(key)


## Saves cache metadata to [code]cache.json[/code].
func save() -> Error:
	var path: String = _path()
	var part_path: String = "%s.tmp" % path
	var latest_items: Dictionary = _load_items(path)
	latest_items.merge(_items, true)
	for key in _removed_keys:
		latest_items.erase(key)

	var file: FileAccess = FileAccess.open(part_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()

	file.store_string(JSON.stringify({"schema": _SCHEMA, "items": latest_items}, "\t"))
	file = null

	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

	return DirAccess.rename_absolute(part_path, path)


func _path() -> String:
	return _cache_dir.path_join("cache.json")


static func _load_items(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary and parsed.has("items") and (parsed["items"] is Dictionary):
		return parsed["items"]

	return {}
