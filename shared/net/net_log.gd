class_name NetLog extends RefCounted


static func print_line(message: Variant) -> void:
	print("%s %s" % [_timestamp(), str(message)])


static func _timestamp() -> String:
	var unix_time := Time.get_unix_time_from_system()
	var seconds := floori(unix_time)
	var milliseconds := int(round((unix_time - float(seconds)) * 1000.0))
	if milliseconds >= 1000:
		seconds += 1
		milliseconds = 0

	var datetime := Time.get_datetime_dict_from_unix_time(seconds)
	return "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ" % [
		int(datetime["year"]),
		int(datetime["month"]),
		int(datetime["day"]),
		int(datetime["hour"]),
		int(datetime["minute"]),
		int(datetime["second"]),
		milliseconds,
	]
