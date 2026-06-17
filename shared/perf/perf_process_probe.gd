class_name PerfProcessProbe extends RefCounted

const LINUX_CLOCK_TICKS_PER_SECOND := 100.0

var previous_process_ticks := -1.0
var previous_total_ticks := -1.0
var previous_net_rx_bytes := -1
var previous_net_tx_bytes := -1


func sample() -> Dictionary:
	var metrics: Dictionary = {
		"rss_mb": _round(_linux_rss_mb(), 2),
		"vm_mb": _round(_linux_vm_mb(), 2),
		"static_mb": _round(_godot_static_memory_mb(), 2),
		"static_max_mb": _round(_godot_static_memory_max_mb(), 2),
		"cpu_pct": 0.0,
		"host_net_rx_mb": 0.0,
		"host_net_tx_mb": 0.0,
		"host_net_rx_kbps": 0.0,
		"host_net_tx_kbps": 0.0,
	}
	_add_cpu_metrics(metrics)
	_add_network_metrics(metrics)
	return metrics


func _add_cpu_metrics(metrics: Dictionary) -> void:
	var process_ticks: float = _linux_process_ticks()
	var total_ticks: float = _linux_total_cpu_ticks()
	if process_ticks < 0.0 or total_ticks <= 0.0:
		return
	if previous_process_ticks >= 0.0 and previous_total_ticks > 0.0:
		var process_delta: float = process_ticks - previous_process_ticks
		var total_delta: float = total_ticks - previous_total_ticks
		if total_delta > 0.0 and process_delta >= 0.0:
			var cpu_count: int = maxi(OS.get_processor_count(), 1)
			metrics["cpu_pct"] = _round((process_delta / total_delta) * float(cpu_count) * 100.0, 2)
	previous_process_ticks = process_ticks
	previous_total_ticks = total_ticks


func _add_network_metrics(metrics: Dictionary) -> void:
	var totals: Dictionary = _linux_network_bytes()
	if totals.is_empty():
		return
	var rx_bytes := int(totals.get("rx", 0))
	var tx_bytes := int(totals.get("tx", 0))
	metrics["host_net_rx_mb"] = _round(float(rx_bytes) / 1048576.0, 2)
	metrics["host_net_tx_mb"] = _round(float(tx_bytes) / 1048576.0, 2)
	if previous_net_rx_bytes >= 0:
		var rx_delta: int = maxi(rx_bytes - previous_net_rx_bytes, 0)
		var tx_delta: int = maxi(tx_bytes - previous_net_tx_bytes, 0)
		metrics["host_net_rx_kbps"] = _round(float(rx_delta) / 1024.0, 2)
		metrics["host_net_tx_kbps"] = _round(float(tx_delta) / 1024.0, 2)
	previous_net_rx_bytes = rx_bytes
	previous_net_tx_bytes = tx_bytes


func _linux_rss_mb() -> float:
	var status := _read_text_file("/proc/self/status")
	if status.is_empty():
		return 0.0
	for line in status.split("\n"):
		if line.begins_with("VmRSS:"):
			return float(_first_int(line)) / 1024.0
	return 0.0


func _linux_vm_mb() -> float:
	var status := _read_text_file("/proc/self/status")
	if status.is_empty():
		return 0.0
	for line in status.split("\n"):
		if line.begins_with("VmSize:"):
			return float(_first_int(line)) / 1024.0
	return 0.0


func _linux_process_ticks() -> float:
	var stat := _read_text_file("/proc/self/stat")
	if stat.is_empty():
		return -1.0
	var close_index := stat.rfind(")")
	if close_index < 0 or close_index + 2 >= stat.length():
		return -1.0
	var fields := stat.substr(close_index + 2).split(" ", false)
	if fields.size() <= 12:
		return -1.0
	var user_ticks := float(fields[11])
	var system_ticks := float(fields[12])
	return user_ticks + system_ticks


func _linux_total_cpu_ticks() -> float:
	var stat := _read_text_file("/proc/stat")
	if stat.is_empty():
		return -1.0
	var first_line := stat.split("\n", false)[0]
	var fields := first_line.split(" ", false)
	var total := 0.0
	for i in range(1, fields.size()):
		total += float(fields[i])
	return total


func _linux_network_bytes() -> Dictionary:
	var text := _read_text_file("/proc/net/dev")
	if text.is_empty():
		return {}
	var rx := 0
	var tx := 0
	for line in text.split("\n", false):
		if not line.contains(":"):
			continue
		var parts := line.split(":", false, 1)
		var iface := parts[0].strip_edges()
		if iface == "lo":
			continue
		var fields := parts[1].split(" ", false)
		if fields.size() < 16:
			continue
		rx += int(fields[0])
		tx += int(fields[8])
	return {"rx": rx, "tx": tx}


func _godot_static_memory_mb() -> float:
	return float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0


func _godot_static_memory_max_mb() -> float:
	return float(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)) / 1048576.0


func _read_text_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


func _first_int(text: String) -> int:
	var digits := ""
	for i in range(text.length()):
		var character := text[i]
		if character >= "0" and character <= "9":
			digits += character
		elif not digits.is_empty():
			break
	return int(digits) if not digits.is_empty() else 0


func _round(value: float, digits: int) -> float:
	var scale := pow(10.0, digits)
	return round(value * scale) / scale
