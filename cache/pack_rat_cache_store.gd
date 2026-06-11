class_name PackRatCacheStore
extends RefCounted


func configure(cache_dir: String) -> void:
	pass


func load_cache() -> void:
	pass


func get_record(cache_key: String) -> Dictionary:
	return {}


func set_record(cache_key: String, record: Dictionary) -> void:
	pass


func save() -> Error:
	return OK
