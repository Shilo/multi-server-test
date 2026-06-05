class_name CliArgs

static func get_value(args: PackedStringArray, key: String, default_value: String = "") -> String:
	var flag := "--" + key
	for i in range(args.size()):
		var arg := args[i]
		if arg == flag and i + 1 < args.size():
			return args[i + 1]
		if arg.begins_with(flag + "="):
			return arg.substr(flag.length() + 1)
	return default_value


static func has_flag(args: PackedStringArray, key: String) -> bool:
	var flag := "--" + key
	for arg in args:
		if arg == flag or arg.begins_with(flag + "="):
			return true
	return false
