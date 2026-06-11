class_name PackRatValidationResult
extends RefCounted

var ok: bool = true
var error: String = ""
var sha256: String = ""
var warnings: PackedStringArray = []


static func failed(message: String) -> PackRatValidationResult:
	var result := PackRatValidationResult.new()
	result.ok = false
	result.error = message
	return result


func add_warning(message: String) -> void:
	if message.is_empty():
		return

	warnings.append(message)
