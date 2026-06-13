class_name PackRatOptions extends RefCounted
## Optional settings for [method PackRat.load_resource_pack].

const _DEFAULT_DOWNLOAD_CHUNK_SIZE: int = 8 * 1024 * 1024

## Cache ID used for the URL. Empty means PackRat derives one from the filename.
var id: String = ""

## Directory that stores [code]cache.json[/code], temporary downloads, and cached packs.
var cache_dir: String = "user://pack_rat"

## Whether mounted PCK/ZIP files can replace existing [code]res://[/code] paths.
var replace_files: bool = true

## Byte offset for embedded PCK files. Godot does not support nonzero offsets for ZIP packs.
var offset: int = 0

## Optional resource path the caller intends to load after the pack is ready.
var entry_path: String = ""

## Expected byte size for this pack. A value above [code]0[/code] becomes part
## of the cache identity and is checked after download.
var expected_size: int = 0

## Expected modified time for this pack, usually a server-provided Unix
## timestamp. A value above [code]0[/code] becomes part of the cache identity.
var expected_modified_time: int = 0

## Optional byte total used only for progress when the platform cannot report a
## reliable HTTP body size. Unlike [member expected_size], this does not validate
## downloads or change cache identity.
var progress_total_size: int = 0

## Reuses an existing matching cache file immediately without checking for
## remote updates. Cache misses still download normally.
var offline_first: bool = false

## Extra HTTP headers passed to HEAD and GET requests.
var request_headers: PackedStringArray = []

## Whether [HTTPRequest] may use gzip/deflate transfer compression. Native
## Godot decodes compressed responses before PackRat writes the cached file.
## Web browsers decode fetch bodies before Godot reads them, so PackRat avoids
## asking Web [HTTPRequest] to decode the same body twice.
var accept_gzip: bool = true

## HTTP timeout in seconds. This should stay finite so stalled downloads fail.
var timeout_seconds: float = 120.0

## Bytes per native [HTTPRequest] read or Web [code]fetch()[/code] write chunk.
## PackRat defaults to a large balanced chunk for DLC-sized files.
var download_chunk_size: int = _DEFAULT_DOWNLOAD_CHUNK_SIZE

## Runs native [HTTPRequest] polling on its worker thread when supported. Enable
## this after profiling a real native download that benefits from it. PackRat
## does not pass this through to Web [HTTPRequest].
var use_threads: bool = false

## Uses PackRat's browser [code]fetch()[/code] downloader for Web exports when
## available. Disable this to force Godot's [HTTPRequest] path for comparison
## or debugging.
var use_web_fetch: bool = true

## Captures millisecond phase timings in [member PackRatResult.timings_msec].
## Disabled by default to keep production loads as lean as possible.
var capture_timings: bool = false

## Maximum HTTP redirects followed by [HTTPRequest].
var max_redirects: int = 8

## Forces a fresh download instead of using a matching cached pack.
var always_download: bool = false


## Creates options with server-provided expected file metadata.
static func from_expected_metadata(expected_modified_time: int, expected_size: int) -> PackRatOptions:
	var options: PackRatOptions = PackRatOptions.new()
	options.expected_modified_time = expected_modified_time
	options.expected_size = expected_size
	return options


## Returns [code]true[/code] when [member expected_size] should be checked.
func has_expected_size() -> bool:
	return expected_size > 0


## Returns [code]true[/code] when [member expected_modified_time] should be checked.
func has_expected_modified_time() -> bool:
	return expected_modified_time > 0


## Returns [code]true[/code] when server-provided cache identity is available.
func has_expected_metadata() -> bool:
	return has_expected_size() or has_expected_modified_time()


## Returns a snapshot so async requests are not affected by later mutations.
func copy() -> PackRatOptions:
	var options: PackRatOptions = PackRatOptions.new()
	options.id = id
	options.cache_dir = cache_dir
	options.replace_files = replace_files
	options.offset = offset
	options.entry_path = entry_path
	options.expected_size = expected_size
	options.expected_modified_time = expected_modified_time
	options.progress_total_size = progress_total_size
	options.offline_first = offline_first
	options.request_headers = request_headers.duplicate()
	options.accept_gzip = accept_gzip
	options.timeout_seconds = timeout_seconds
	options.download_chunk_size = download_chunk_size
	options.use_threads = use_threads
	options.use_web_fetch = use_web_fetch
	options.capture_timings = capture_timings
	options.max_redirects = max_redirects
	options.always_download = always_download
	return options
