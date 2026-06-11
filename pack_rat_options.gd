class_name PackRatOptions extends RefCounted
## Optional settings for [method PackRat.prepare].

## Cache ID used for the URL. Empty means PackRat derives one from the filename.
var id: String = ""

## Directory that stores [code]cache.json[/code], temporary downloads, and cached packs.
var cache_dir: String = "user://pack_rat"

## Whether mounted PCK/ZIP files can replace existing [code]res://[/code] paths.
var replace_files: bool = true

## Optional resource path the caller intends to load after the pack is ready.
var entry_path: String = ""

## Expected byte size for this pack. A value above [code]0[/code] becomes part
## of the cache identity and is checked after download.
var expected_size: int = 0

## Expected modified time for this pack, usually a server-provided Unix
## timestamp. A value above [code]0[/code] becomes part of the cache identity.
var expected_modified_time: int = 0

## Reuses an existing matching cache file immediately without checking for
## remote updates. Cache misses still download normally.
var offline_first: bool = false

## Extra HTTP headers passed to HEAD and GET requests.
var request_headers: PackedStringArray = []

## HTTP timeout in seconds. This should stay finite so stalled downloads fail.
var timeout_seconds: float = 120.0

## Maximum HTTP redirects followed by [HTTPRequest].
var max_redirects: int = 8

## Forces a fresh download instead of using a matching cached pack.
var always_download: bool = false


## Returns [code]true[/code] when server-provided cache identity is available.
func has_expected_metadata() -> bool:
	return expected_size > 0 or expected_modified_time > 0
