class_name PerfNetworkProbe extends RefCounted


func sample_api(label: String, api: MultiplayerAPI) -> Dictionary:
	if api == null:
		return {}
	var peer: Object = api.multiplayer_peer
	if peer == null:
		return {}

	var safe_label := _safe(label)
	var metrics := {
		"%s_peer_count" % safe_label: api.get_peers().size(),
		"%s_unique_id" % safe_label: api.get_unique_id(),
		"%s_connection_status" % safe_label: peer.get_connection_status(),
		"%s_available_packets" % safe_label: peer.get_available_packet_count(),
		"%s_refusing_connections" % safe_label: int(peer.is_refusing_new_connections()),
	}
	_add_websocket_metrics(metrics, safe_label, api, peer)
	_add_enet_metrics(metrics, safe_label, api, peer)
	return metrics


func _add_websocket_metrics(metrics: Dictionary, label: String, api: MultiplayerAPI, peer: Object) -> void:
	if not peer.has_method("get_peer"):
		return

	var buffered_total := 0
	var open_peers := 0
	for peer_id in _transport_peer_ids(api, peer):
		var socket_peer: Variant = peer.get_peer(int(peer_id))
		if socket_peer == null:
			continue
		if socket_peer.has_method("get_ready_state"):
			open_peers += int(socket_peer.get_ready_state() == WebSocketPeer.STATE_OPEN)
		if socket_peer.has_method("get_current_outbound_buffered_amount"):
			buffered_total += int(socket_peer.get_current_outbound_buffered_amount())

	metrics["%s_ws_open_peers" % label] = open_peers
	metrics["%s_ws_outbound_buffered_bytes" % label] = buffered_total
	if peer.has_method("get_inbound_buffer_size"):
		metrics["%s_ws_inbound_buffer_size" % label] = int(peer.get_inbound_buffer_size())
	if peer.has_method("get_outbound_buffer_size"):
		metrics["%s_ws_outbound_buffer_size" % label] = int(peer.get_outbound_buffer_size())
	if peer.has_method("get_max_queued_packets"):
		metrics["%s_ws_max_queued_packets" % label] = int(peer.get_max_queued_packets())


func _add_enet_metrics(metrics: Dictionary, label: String, api: MultiplayerAPI, peer: Object) -> void:
	if not peer.has_method("get_peer"):
		return

	var rtt_total := 0.0
	var rtt_count := 0
	var packet_loss_total := 0.0
	for peer_id in _transport_peer_ids(api, peer):
		var enet_peer: Variant = peer.get_peer(int(peer_id))
		if enet_peer == null or not enet_peer.has_method("get_statistic"):
			continue
		rtt_total += float(enet_peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
		packet_loss_total += float(enet_peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS))
		rtt_count += 1

	if rtt_count <= 0:
		return
	metrics["%s_enet_rtt_avg_msec" % label] = _round(rtt_total / float(rtt_count), 2)
	metrics["%s_enet_packet_loss_avg" % label] = _round(packet_loss_total / float(rtt_count), 4)


func _safe(value: String) -> String:
	return value.replace("-", "_").replace(" ", "_").to_lower()


func _transport_peer_ids(api: MultiplayerAPI, peer: Object) -> Array[int]:
	var peer_ids: Array[int] = []
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return peer_ids
	if api.is_server():
		for peer_id in api.get_peers():
			peer_ids.append(int(peer_id))
	else:
		peer_ids.append(MultiplayerPeer.TARGET_PEER_SERVER)
	return peer_ids


func _round(value: float, digits: int) -> float:
	var scale := pow(10.0, digits)
	return round(value * scale) / scale
