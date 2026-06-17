class_name PerfCounters extends RefCounted

var counters := {}
var gauges := {}
var previous_counters := {}


func increment(name: String, amount := 1) -> void:
	counters[name] = int(counters.get(name, 0)) + amount


func add_bytes(name: String, amount: int) -> void:
	if amount <= 0:
		return
	increment(name, amount)


func set_gauge(name: String, value: Variant) -> void:
	gauges[name] = value


func snapshot() -> Dictionary:
	var result := {}
	for key in counters.keys():
		var current := int(counters[key])
		var previous := int(previous_counters.get(key, 0))
		result["%s_total" % key] = current
		result["%s_delta" % key] = current - previous
		previous_counters[key] = current
	for key in gauges.keys():
		result[key] = gauges[key]
	return result
