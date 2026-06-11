class_name PackRatCachePaths extends RefCounted
## Internal cache naming and path-safety helpers for PackRat.

const _HASH_TOKEN_LENGTH: int = 12


static func local_path(
	url: String,
	cache_dir: String,
	id: String,
	metadata: PackRatHttpResponse,
	options: PackRatOptions
) -> String:
	var filename: String = filename_from_url(url)
	var extension: String = filename.get_extension()
	var token: String = version_token(url, metadata, options)
	if extension.is_empty():
		extension = extension_for_response(metadata)

	return cache_dir.path_join("%s-%s.%s" % [id, token, extension])


static func version_token(url: String, metadata: PackRatHttpResponse, options: PackRatOptions) -> String:
	if options.has_expected_metadata():
		return expected_metadata_token(options)

	if not metadata.etag.is_empty():
		return metadata.etag.sha256_text().substr(0, _HASH_TOKEN_LENGTH)

	if not metadata.last_modified.is_empty() or metadata.content_length > 0:
		return ("%s:%d" % [metadata.last_modified, metadata.content_length]).sha256_text().substr(0, _HASH_TOKEN_LENGTH)

	return url.sha256_text().substr(0, _HASH_TOKEN_LENGTH)


static func id_for_url(url: String, options: PackRatOptions) -> String:
	if not options.id.is_empty():
		return safe_name(options.id)

	return safe_name(filename_from_url(url).get_basename())


static func cache_key(url: String, id: String, options: PackRatOptions) -> String:
	if options.has_expected_metadata():
		return "%s-%s" % [id, expected_metadata_token(options)]

	return "%s-%s" % [id, url.sha256_text().substr(0, _HASH_TOKEN_LENGTH)]


static func expected_metadata_token(options: PackRatOptions) -> String:
	return ("expected:%d:%d" % [options.expected_size, options.expected_modified_time]).sha256_text().substr(0, _HASH_TOKEN_LENGTH)


static func extension_for_response(metadata: PackRatHttpResponse) -> String:
	if metadata.content_type.to_lower().contains("zip"):
		return "zip"

	return "pck"


static func record_matches(value: String, key: String, record: PackRatCacheRecord) -> bool:
	if is_http_url(value):
		return record.source_url == value

	if key == value:
		return true

	if record.local_path == value:
		return true

	var safe_value: String = safe_name(value)
	if record_id(key, record) == safe_value:
		return true

	return record.local_path.get_file() == value or filename_from_url(record.source_url) == value


static func record_id(key: String, record: PackRatCacheRecord) -> String:
	if not record.id.is_empty():
		return record.id

	var filename_id: String = id_from_cached_filename(record.local_path.get_file())
	if not filename_id.is_empty():
		return filename_id

	var separator: int = key.rfind("-")
	return key.substr(0, separator) if separator > 0 else key


static func id_from_cached_filename(filename: String) -> String:
	var basename: String = filename.get_basename()
	var separator: int = basename.rfind("-")
	if separator <= 0:
		return ""

	return basename.substr(0, separator)


static func unused_cache_path(path: String, salt: int) -> String:
	var directory: String = path.get_base_dir()
	var basename: String = path.get_file().get_basename()
	var extension: String = path.get_extension()
	for index in range(100):
		var suffix: String = "%d-%d" % [salt, index]
		var candidate: String = "%s-%s" % [basename, suffix]
		if not extension.is_empty():
			candidate = "%s.%s" % [candidate, extension]
		var candidate_path: String = directory.path_join(candidate)
		if not FileAccess.file_exists(candidate_path):
			return candidate_path

	var fallback: String = "%s-%d" % [basename, Time.get_ticks_usec()]
	var fallback_filename: String = "%s.%s" % [fallback, extension] if not extension.is_empty() else fallback
	return directory.path_join(fallback_filename)


static func filename_from_url(url: String) -> String:
	var clean_url: String = url
	var query_index: int = clean_url.find("?")
	if query_index >= 0:
		clean_url = clean_url.substr(0, query_index)

	var hash_index: int = clean_url.find("#")
	if hash_index >= 0:
		clean_url = clean_url.substr(0, hash_index)

	var filename: String = clean_url.get_file()
	return filename if not filename.is_empty() else "pack.pck"


static func is_http_url(value: String) -> bool:
	return value.begins_with("http://") or value.begins_with("https://")


static func safe_name(value: String) -> String:
	var output: PackedStringArray = []
	for index in range(value.length()):
		var character: String = value.substr(index, 1).to_lower()
		if character in "abcdefghijklmnopqrstuvwxyz0123456789._-":
			output.append(character)
		else:
			output.append("_")

	return "".join(output) if not output.is_empty() else "pack"


static func is_cache_pack_file(filename: String) -> bool:
	var extension: String = filename.get_extension().to_lower()
	return extension == "pck" or extension == "zip"


static func cached_filename_matches_id(filename: String, id: String) -> bool:
	return is_cache_pack_file(filename) and id_from_cached_filename(filename) == id


static func is_safe_cache_dir(path: String) -> bool:
	var normalized: String = normalized_cache_dir(path)
	return (
		normalized.begins_with("user://")
		and normalized != "user://"
		and not has_parent_directory_segment(path)
		and not has_parent_directory_segment(normalized)
	)


static func is_cache_child_path(path: String, cache_dir: String) -> bool:
	var normalized_cache_root: String = normalized_cache_dir(cache_dir)
	var normalized_path: String = normalized_cache_dir(path)
	if (
		normalized_cache_root.is_empty()
		or has_parent_directory_segment(path)
		or has_parent_directory_segment(cache_dir)
		or has_parent_directory_segment(normalized_path)
		or has_parent_directory_segment(normalized_cache_root)
	):
		return false

	return normalized_path.begins_with("%s/" % normalized_cache_root)


static func normalized_cache_dir(path: String) -> String:
	var normalized: String = path.strip_edges().replace("\\", "/").simplify_path()
	while normalized.ends_with("/") and normalized != "user://" and normalized != "res://":
		normalized = normalized.trim_suffix("/")

	return normalized


static func has_parent_directory_segment(path: String) -> bool:
	for segment in path.replace("\\", "/").split("/", false):
		if segment == "..":
			return true

	return false
