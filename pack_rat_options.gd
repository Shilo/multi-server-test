class_name PackRatOptions
extends RefCounted

enum InstallMode {
	AUTO,
	RESOURCE_PACK,
	FILE,
}

enum FreshnessMode {
	AUTO,
	ALWAYS_CHECK,
	CACHE_FIRST,
	ALWAYS_DOWNLOAD,
}

var id: String = ""
var cache_key: String = ""
var cache_dir: String = "user://pack_rat"
var install_mode: InstallMode = InstallMode.AUTO
var freshness_mode: FreshnessMode = FreshnessMode.AUTO
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

var source_resolver: PackRatSourceResolver
var freshness_checker: PackRatFreshnessChecker
var cache_store: PackRatCacheStore
var installer: PackRatInstaller
var validators: Array[PackRatValidator] = []


func copy() -> PackRatOptions:
	var options := PackRatOptions.new()
	options.id = id
	options.cache_key = cache_key
	options.cache_dir = cache_dir
	options.install_mode = install_mode
	options.freshness_mode = freshness_mode
	options.replace_files = replace_files
	options.entry_path = entry_path
	options.expected_sha256 = expected_sha256
	options.expected_size = expected_size
	options.request_headers = request_headers.duplicate()
	options.timeout_seconds = timeout_seconds
	options.head_timeout_seconds = head_timeout_seconds
	options.max_redirects = max_redirects
	options.allow_unverified_remote = allow_unverified_remote
	options.download_when_freshness_unknown = download_when_freshness_unknown
	options.source_resolver = source_resolver
	options.freshness_checker = freshness_checker
	options.cache_store = cache_store
	options.installer = installer
	options.validators = validators.duplicate()
	return options
