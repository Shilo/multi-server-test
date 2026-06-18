extends SceneTree

const NET_CONFIG := preload("res://shared/net/net_config.gd")

var failures := 0


func _init() -> void:
	_clear_test_environment()
	_expect("default_bind", NET_CONFIG.bind_host(), "*")
	_expect("default_master_url", NET_CONFIG.master_url(), "ws://127.0.0.1:19080")
	_expect("default_hub_url", NET_CONFIG.world_url("hub"), "ws://127.0.0.1:19081")

	OS.set_environment(NET_CONFIG.BIND_HOST_ENV, "127.0.0.1")
	OS.set_environment(NET_CONFIG.PUBLIC_MASTER_URL_ENV, "wss://game.example.test/")
	OS.set_environment(NET_CONFIG.PUBLIC_WORLD_URL_TEMPLATE_ENV, "wss://game.example.test/{world_key}")

	_expect("override_bind", NET_CONFIG.bind_host(), "127.0.0.1")
	_expect("override_master_url", NET_CONFIG.master_url(), "wss://game.example.test/")
	_expect("override_hub_url", NET_CONFIG.world_url("hub"), "wss://game.example.test/hub")
	_expect("override_left_world_url", NET_CONFIG.world_url("left_world"), "wss://game.example.test/left_world")

	_clear_test_environment()
	if failures == 0:
		print("NET_CONFIG_SMOKE_PASS")
	else:
		push_error("NET_CONFIG_SMOKE_FAIL failures=%d" % failures)
	quit(failures)


func _clear_test_environment() -> void:
	OS.unset_environment(NET_CONFIG.BIND_HOST_ENV)
	OS.unset_environment(NET_CONFIG.PUBLIC_MASTER_URL_ENV)
	OS.unset_environment(NET_CONFIG.PUBLIC_WORLD_URL_TEMPLATE_ENV)
	OS.unset_environment(NET_CONFIG.CLIENT_HOST_ENV)
	OS.unset_environment(NET_CONFIG.CLIENT_SCHEME_ENV)


func _expect(label: String, actual: String, expected: String) -> void:
	if actual == expected:
		print("NET_CONFIG_SMOKE_STEP %s ok value=%s" % [label, actual])
		return
	failures += 1
	push_error("NET_CONFIG_SMOKE_STEP %s expected=%s actual=%s" % [label, expected, actual])
