class_name PackRatFreshnessDecision
extends RefCounted

var should_download: bool = true
var use_cache: bool = false
var status: String = PackRatResult.STATUS_DOWNLOADED
var reason: String = ""
var record: Dictionary = {}
var metadata: Dictionary = {}
var warnings: PackedStringArray = []
var error: String = ""


func add_warning(message: String) -> void:
	if message.is_empty():
		return

	warnings.append(message)
