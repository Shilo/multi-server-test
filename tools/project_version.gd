extends SceneTree

const VERSION_SETTING := "application/config/version"
const DEFAULT_VERSION := "0.1"


func _init() -> void:
	quit(_run(OS.get_cmdline_user_args()))


func _run(args: PackedStringArray) -> int:
	if args.size() == 0 or args.has("--print"):
		return _print_version()

	if args.has("--bump-minor"):
		return _bump_minor()

	var set_index := args.find("--set")
	if set_index >= 0:
		if set_index + 1 >= args.size():
			push_error("Missing version after --set.")
			return 2
		return _set_version(args[set_index + 1])

	_print_usage()
	return 2


func _print_version() -> int:
	var version := _current_version()
	if not _is_valid_version(version):
		push_error("Invalid %s: %s" % [VERSION_SETTING, version])
		return 2

	print("PROJECT_VERSION version=%s" % version)
	return 0


func _bump_minor() -> int:
	var version := _current_version()
	if not _is_valid_version(version):
		push_error("Invalid %s: %s" % [VERSION_SETTING, version])
		return 2

	var parts := version.split(".")
	var major := int(parts[0])
	var minor := int(parts[1]) + 1
	if minor > 9:
		major += 1
		minor = 0

	return _set_version("%d.%d" % [major, minor])


func _set_version(version: String) -> int:
	var clean_version := version.strip_edges()
	if not _is_valid_version(clean_version):
		push_error("Version must use MAJOR.MINOR with MINOR from 0 to 9, got: %s" % version)
		return 2

	ProjectSettings.set_setting(VERSION_SETTING, clean_version)
	var error := ProjectSettings.save()
	if error != OK:
		push_error("Could not save project version %s (error %d)." % [clean_version, error])
		return 1

	print("PROJECT_VERSION_SET version=%s" % clean_version)
	return 0


func _current_version() -> String:
	return str(ProjectSettings.get_setting(VERSION_SETTING, DEFAULT_VERSION)).strip_edges()


func _is_valid_version(version: String) -> bool:
	var parts := version.split(".")
	if parts.size() != 2:
		return false
	if not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return false

	var major := int(parts[0])
	var minor := int(parts[1])
	return major >= 0 and minor >= 0 and minor <= 9


func _print_usage() -> void:
	push_error("Usage: --print | --set MAJOR.MINOR | --bump-minor")
