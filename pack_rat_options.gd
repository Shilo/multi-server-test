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

## Extra HTTP headers passed to HEAD and GET requests.
var request_headers: PackedStringArray = []

## HTTP timeout in seconds. This should stay finite so stalled downloads fail.
var timeout_seconds: float = 120.0

## Maximum HTTP redirects followed by [HTTPRequest].
var max_redirects: int = 8

## Forces a fresh download instead of using a matching cached pack.
var always_download: bool = false
