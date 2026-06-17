static func is_peer_open(api: MultiplayerAPI, peer_id: int) -> bool:
	if not (peer_id in api.get_peers()):
		return false

	var peer := api.multiplayer_peer
	if not peer or not peer.has_method("get_peer"):
		return true

	var socket = peer.get_peer(peer_id)
	if not socket or not socket.has_method("get_ready_state"):
		return true

	return socket.get_ready_state() == WebSocketPeer.STATE_OPEN


static func disconnect_peer(api: MultiplayerAPI, peer_id: int) -> void:
	var peer := api.multiplayer_peer
	if peer and peer.has_method("disconnect_peer"):
		peer.disconnect_peer(peer_id)
