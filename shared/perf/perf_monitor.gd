class_name PerfMonitor extends Node

const DEFAULT_INTERVAL_SECONDS := 5.0

var role := ""
var instance_id := ""
var counters := PerfCounters.new()
var probe := PerfProcessProbe.new()
var network_probe := PerfNetworkProbe.new()
var extra_stats_callable := Callable()
var multiplayer_apis := {}
var sample_timer: Timer
var started_msec := 0
var last_frames_drawn := 0
var sample_interval_seconds := DEFAULT_INTERVAL_SECONDS


func configure(new_role: String, new_instance_id := "", extra_stats := Callable(), interval_seconds := DEFAULT_INTERVAL_SECONDS) -> void:
	role = new_role
	instance_id = new_instance_id
	extra_stats_callable = extra_stats
	sample_interval_seconds = interval_seconds
	if sample_timer:
		sample_timer.wait_time = sample_interval_seconds


func _ready() -> void:
	started_msec = Time.get_ticks_msec()
	sample_timer = Timer.new()
	sample_timer.name = "PerfSampleTimer"
	sample_timer.wait_time = sample_interval_seconds
	sample_timer.autostart = true
	sample_timer.timeout.connect(_emit_sample)
	add_child(sample_timer)
	_emit_sample()


func increment(name: String, amount := 1) -> void:
	counters.increment(name, amount)


func add_bytes(name: String, amount: int) -> void:
	counters.add_bytes(name, amount)


func set_gauge(name: String, value: Variant) -> void:
	counters.set_gauge(name, value)


func observe_latency(name: String, latency_msec: int) -> void:
	if latency_msec < 0:
		return
	counters.increment("%s_count" % name)
	counters.increment("%s_msec" % name, latency_msec)
	counters.set_gauge("%s_last_msec" % name, latency_msec)


func register_multiplayer_api(label: String, api: MultiplayerAPI) -> void:
	if label.is_empty() or api == null:
		return
	multiplayer_apis[label] = api


func _emit_sample() -> void:
	var sample := _base_sample()
	sample.merge(probe.sample(), true)
	sample.merge(counters.snapshot(), true)
	for label in multiplayer_apis.keys():
		var api: MultiplayerAPI = multiplayer_apis[label]
		if api != null:
			sample.merge(network_probe.sample_api(str(label), api), true)
	if extra_stats_callable.is_valid():
		var extra: Variant = extra_stats_callable.call()
		if typeof(extra) == TYPE_DICTIONARY:
			sample.merge(extra, true)
	NetLog.print_line("PERF_SAMPLE %s" % _format_pairs(sample))


func _base_sample() -> Dictionary:
	var frames_drawn: int = Engine.get_frames_drawn()
	var frame_delta: int = maxi(frames_drawn - last_frames_drawn, 0)
	last_frames_drawn = frames_drawn
	return {
		"role": role,
		"instance": instance_id,
		"pid": OS.get_process_id(),
		"uptime_sec": _round(float(Time.get_ticks_msec() - started_msec) / 1000.0, 2),
		"fps": _round(Performance.get_monitor(Performance.TIME_FPS), 2),
		"process_msec": _round(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 3),
		"physics_msec": _round(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 3),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"frames_delta": frame_delta,
	}


func _format_pairs(sample: Dictionary) -> String:
	var keys := sample.keys()
	keys.sort()
	var parts: Array[String] = []
	for key in keys:
		parts.append("%s=%s" % [key, _format_value(sample[key])])
	return " ".join(parts)


func _format_value(value: Variant) -> String:
	match typeof(value):
		TYPE_FLOAT:
			return "%.3f" % float(value)
		TYPE_STRING:
			return String(value).replace(" ", "_")
		TYPE_STRING_NAME:
			return String(value).replace(" ", "_")
		_:
			return str(value).replace(" ", "_")


func _round(value: float, digits: int) -> float:
	var scale := pow(10.0, digits)
	return round(value * scale) / scale
