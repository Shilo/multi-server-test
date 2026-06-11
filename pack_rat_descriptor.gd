class_name PackRatDescriptor
extends RefCounted

var ok: bool = true
var error: String = ""
var id: String = ""
var cache_key: String = ""
var cache_dir: String = "user://pack_rat"
var source_url: String = ""
var final_url: String = ""
var local_filename: String = ""
var install_mode: PackRatOptions.InstallMode = PackRatOptions.InstallMode.AUTO
var freshness_mode: PackRatOptions.FreshnessMode = PackRatOptions.FreshnessMode.AUTO
var replace_files: bool = false
var entry_path: String = ""
var expected_sha256: String = ""
var expected_size: int = 0
var request_headers: PackedStringArray = []
var timeout_seconds: float = 0.0
var head_timeout_seconds: float = 10.0
var max_redirects: int = 8
var allow_unverified_remote: bool = true
var download_when_freshness_unknown: bool = false


static func from_url(url: String, options: PackRatOptions) -> PackRatDescriptor:
	var descriptor := PackRatDescriptor.new()
	descriptor.source_url = url.strip_edges()
	descriptor.final_url = descriptor.source_url
	descriptor._apply_options(options)

	if descriptor.source_url.is_empty():
		return invalid("PackRat.prepare() needs a non-empty URL.")

	var clean_url := _strip_url_suffix(descriptor.source_url)
	descriptor.local_filename = clean_url.get_file()
	if descriptor.local_filename.is_empty():
		descriptor.local_filename = "pack.pck"

	if descriptor.id.is_empty():
		descriptor.id = _sanitize(descriptor.local_filename.get_basename())

	if descriptor.cache_key.is_empty():
		descriptor.cache_key = "%s-%s" % [
			_sanitize(descriptor.id),
			descriptor.source_url.sha256_text().substr(0, 12),
		]

	descriptor.id = _sanitize(descriptor.id)
	descriptor.cache_key = _sanitize(descriptor.cache_key)
	descriptor._infer_install_mode()
	return descriptor


static func from_dictionary(data: Dictionary, options: PackRatOptions) -> PackRatDescriptor:
	var descriptor := PackRatDescriptor.new()
	descriptor.source_url = str(data.get("url", data.get("source_url", data.get("pack_url", "")))).strip_edges()
	descriptor.final_url = str(data.get("final_url", descriptor.source_url))
	descriptor._apply_options(options)

	descriptor.id = str(data.get("id", data.get("key", descriptor.id)))
	descriptor.cache_key = str(data.get("cache_key", descriptor.cache_key))
	descriptor.entry_path = str(data.get("entry_path", data.get("entry", data.get("scene", descriptor.entry_path))))
	descriptor.expected_sha256 = str(data.get("sha256", data.get("pack_sha256", data.get("expected_sha256", descriptor.expected_sha256)))).to_lower()
	descriptor.expected_size = int(data.get("size", data.get("pack_size", data.get("expected_size", descriptor.expected_size))))
	descriptor.replace_files = bool(data.get("replace_files", descriptor.replace_files))

	if data.has("install_mode") or data.has("install"):
		descriptor.install_mode = _install_mode_from_variant(data.get("install_mode", data.get("install")))

	if data.has("freshness_mode"):
		descriptor.freshness_mode = _freshness_mode_from_variant(data["freshness_mode"])

	if descriptor.source_url.is_empty():
		return invalid("PackRat descriptor dictionaries need a url/source_url/pack_url value.")

	var completed := from_url(descriptor.source_url, options)
	completed.final_url = descriptor.final_url
	completed.id = _sanitize(descriptor.id) if not descriptor.id.is_empty() else completed.id
	completed.cache_key = _sanitize(descriptor.cache_key) if not descriptor.cache_key.is_empty() else completed.cache_key
	completed.entry_path = descriptor.entry_path
	completed.expected_sha256 = descriptor.expected_sha256
	completed.expected_size = descriptor.expected_size
	completed.replace_files = descriptor.replace_files
	completed.install_mode = descriptor.install_mode
	completed.freshness_mode = descriptor.freshness_mode
	completed._infer_install_mode()
	return completed


static func from_dict(data: Dictionary, options: PackRatOptions = null) -> PackRatDescriptor:
	return from_dictionary(data, options)


static func invalid(message: String) -> PackRatDescriptor:
	var descriptor := PackRatDescriptor.new()
	descriptor.ok = false
	descriptor.error = message
	return descriptor


func stable_dir() -> String:
	return cache_dir.path_join(id)


func stable_path(version_token: String = "") -> String:
	var extension := local_filename.get_extension()
	var filename := local_filename

	if not version_token.is_empty() and (extension == "pck" or extension == "zip"):
		if _is_hex_sha256(version_token):
			filename = "%s.%s" % [version_token, extension]
		else:
			filename = "%s-%s.%s" % [
				_sanitize(local_filename.get_basename()),
				_sanitize(version_token).substr(0, 16),
				extension,
			]

	return stable_dir().path_join(filename)


func temp_path() -> String:
	return cache_dir.path_join("tmp").path_join("%s.part" % cache_key)


func to_result() -> PackRatResult:
	var result := PackRatResult.new()
	result.id = id
	result.source_url = source_url
	result.final_url = final_url
	result.entry_path = entry_path
	return result


func _apply_options(options: PackRatOptions) -> void:
	if options == null:
		options = PackRatOptions.new()

	id = options.id
	cache_key = options.cache_key
	cache_dir = options.cache_dir
	install_mode = options.install_mode
	freshness_mode = options.freshness_mode
	replace_files = options.replace_files
	entry_path = options.entry_path
	expected_sha256 = options.expected_sha256.to_lower()
	expected_size = options.expected_size
	request_headers = options.request_headers.duplicate()
	timeout_seconds = options.timeout_seconds
	head_timeout_seconds = options.head_timeout_seconds
	max_redirects = options.max_redirects
	allow_unverified_remote = options.allow_unverified_remote
	download_when_freshness_unknown = options.download_when_freshness_unknown


func _infer_install_mode() -> void:
	if install_mode != PackRatOptions.InstallMode.AUTO:
		return

	var extension := local_filename.get_extension().to_lower()
	if extension == "pck" or extension == "zip":
		install_mode = PackRatOptions.InstallMode.RESOURCE_PACK
	else:
		install_mode = PackRatOptions.InstallMode.FILE


static func _strip_url_suffix(url: String) -> String:
	var clean_url := url
	var query_index := clean_url.find("?")
	if query_index >= 0:
		clean_url = clean_url.substr(0, query_index)

	var hash_index := clean_url.find("#")
	if hash_index >= 0:
		clean_url = clean_url.substr(0, hash_index)

	return clean_url


static func _sanitize(value: String) -> String:
	var output := ""
	var lowered := value.strip_edges().to_lower()

	for index in range(lowered.length()):
		var character := lowered.substr(index, 1)
		if character in "abcdefghijklmnopqrstuvwxyz0123456789._-":
			output += character
		else:
			output += "_"

	output = output.strip_edges()
	return output if not output.is_empty() else "pack"


static func _is_hex_sha256(value: String) -> bool:
	if value.length() != 64:
		return false

	for index in range(value.length()):
		var character := value.substr(index, 1).to_lower()
		if not (character in "0123456789abcdef"):
			return false

	return true


static func _install_mode_from_variant(value: Variant) -> PackRatOptions.InstallMode:
	if value is int:
		return int(value)

	match str(value).to_lower():
		"resource_pack", "pck", "zip":
			return PackRatOptions.InstallMode.RESOURCE_PACK
		"file":
			return PackRatOptions.InstallMode.FILE
		_:
			return PackRatOptions.InstallMode.AUTO


static func _freshness_mode_from_variant(value: Variant) -> PackRatOptions.FreshnessMode:
	if value is int:
		return int(value)

	match str(value).to_lower():
		"always_check":
			return PackRatOptions.FreshnessMode.ALWAYS_CHECK
		"cache_first":
			return PackRatOptions.FreshnessMode.CACHE_FIRST
		"always_download":
			return PackRatOptions.FreshnessMode.ALWAYS_DOWNLOAD
		_:
			return PackRatOptions.FreshnessMode.AUTO
