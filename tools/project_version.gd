extends SceneTree

const VERSION_SETTING := "application/config/version"
const DEFAULT_VERSION := "0.1"


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	quit(_run(OS.get_cmdline_user_args()))


func _run(args: PackedStringArray) -> int:
	if args.size() == 0 or args.has("--print"):
		return _print_version()

	if args.has("--self-test"):
		return _self_test()

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

	return _set_version(_next_minor_version(version))


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
	if not _is_canonical_number(parts[0]) or not _is_canonical_number(parts[1]):
		return false

	var major := int(parts[0])
	var minor := int(parts[1])
	return major >= 0 and minor >= 0 and minor <= 9


func _is_canonical_number(value: String) -> bool:
	if not value.is_valid_int():
		return false
	if value.length() > 1 and value.begins_with("0"):
		return false
	return int(value) >= 0


func _next_minor_version(version: String) -> String:
	var parts := version.split(".")
	var major := int(parts[0])
	var minor := int(parts[1]) + 1
	if minor > 9:
		major += 1
		minor = 0
	return "%d.%d" % [major, minor]


func _self_test() -> int:
	if not _is_valid_version("0.1"):
		push_error("Expected 0.1 to be valid.")
		return 1
	if _is_valid_version("1.10") or _is_valid_version("v1.0") or _is_valid_version("abc"):
		push_error("Invalid project version was accepted.")
		return 1
	if _is_valid_version("00.5") or _is_valid_version("01.2") or _is_valid_version("1.09"):
		push_error("Invalid project version was accepted.")
		return 1
	if _next_minor_version("0.8") != "0.9":
		push_error("Expected 0.8 to bump to 0.9.")
		return 1
	if _next_minor_version("0.9") != "1.0":
		push_error("Expected 0.9 to bump to 1.0.")
		return 1
	if _next_minor_version("1.9") != "2.0":
		push_error("Expected 1.9 to bump to 2.0.")
		return 1

	print("PROJECT_VERSION_SELF_TEST_PASS")
	return 0


func _print_usage() -> void:
	push_error("Usage: --print | --set MAJOR.MINOR | --bump-minor | --self-test")
