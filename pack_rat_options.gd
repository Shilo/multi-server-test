class_name PackRatOptions
extends RefCounted

var id: String = ""
var cache_dir: String = "user://pack_rat"
var replace_files: bool = false
var entry_path: String = ""
var request_headers: PackedStringArray = []
var timeout_seconds: float = 0.0
var max_redirects: int = 8
var always_download: bool = false
