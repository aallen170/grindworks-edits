class_name ENetTransport
extends NetTransport
## Direct-IP transport over [ENetMultiplayerPeer] (architecture D2, D4).

func host(port: int, max_clients: int) -> MultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	last_error = peer.create_server(port, max_clients)
	return peer if last_error == OK else null

func join(address: String, port: int) -> MultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	last_error = peer.create_client(address, port)
	return peer if last_error == OK else null
