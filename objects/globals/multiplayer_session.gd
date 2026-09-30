extends Node
## Multiplayer session layer (TGM-38, architecture D2/D4/D5/D9).
##
## Owns host/join over a [NetTransport], the 4-player cap, and the "am I the
## host" concept ([method is_host]) that TGM-27 (host-only dev console, D13)
## depends on.
##
## Deliberately does NOT touch save state (D9): it never calls
## [code]begin_game()[/code], [code]SaveFileService.on_game_over()[/code] or
## anything that deletes [code]current_save.tres[/code]. Starting the actual run
## from a session is M1c/M1d.
##
## Registered as the [code]Session[/code] autoload.

## Emitted once the session is usable: immediately for a host, on connect for a client.
signal session_started(as_host: bool)
## Emitted when a session closes for any reason (left, host gone, join failed).
signal session_ended(reason: String)
## A remote peer connected. On the host this is a joining client.
signal player_joined(peer_id: int)
## A remote peer disconnected. Must never crash the host (M1b acceptance).
signal player_left(peer_id: int)

enum State { OFFLINE, HOSTING, JOINING, JOINED }

## Godot always gives the listen-server peer id 1.
const HOST_PEER_ID := 1
## Hard cap including the host (architecture: "hard cap of 4").
const MAX_PLAYERS := 4
const DEFAULT_PORT := 7777
const JOIN_TIMEOUT_SEC := 10.0

## Swap this to change transport (D2). Nothing else references a concrete peer class.
var transport: NetTransport = ENetTransport.new()
var state: State = State.OFFLINE

## Remote peer ids currently connected (never includes the local peer).
var _remote_peers: Array[int] = []
## Bumped on every join attempt so a stale timeout timer can't kill a newer attempt.
var _join_attempt := 0

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

#region Queries

## True if this instance owns the session. Also true when there is no session
## at all, so single-player keeps the host-only features (dev console, D13)
## that TGM-27 will gate on this. False only while joining or joined as a client.
func is_host() -> bool:
	return state == State.OFFLINE or state == State.HOSTING

## True once a hosted or joined session is live (not merely attempting to join).
func is_session_active() -> bool:
	return state == State.HOSTING or state == State.JOINED

func get_local_peer_id() -> int:
	return multiplayer.get_unique_id() if is_session_active() else HOST_PEER_ID

## Everyone in the session including the local peer, host first.
func get_player_peer_ids() -> Array[int]:
	var ids: Array[int] = []
	if not is_session_active():
		return ids
	ids.append(HOST_PEER_ID)
	var local_id := get_local_peer_id()
	if local_id != HOST_PEER_ID:
		ids.append(local_id)
	var others := _remote_peers.filter(func(id: int) -> bool: return id != HOST_PEER_ID and id != local_id)
	others.sort()
	ids.append_array(others)
	return ids

func get_player_count() -> int:
	return get_player_peer_ids().size()

#endregion

#region Host / join / leave

func host_session(port: int = DEFAULT_PORT) -> Error:
	if state != State.OFFLINE:
		return ERR_ALREADY_IN_USE
	# max_clients excludes the host, so the cap of 4 players is 3 clients.
	var peer := transport.host(port, MAX_PLAYERS - 1)
	if peer == null:
		return transport.last_error
	multiplayer.multiplayer_peer = peer
	_remote_peers.clear()
	state = State.HOSTING
	session_started.emit(true)
	return OK

func join_session(address: String, port: int = DEFAULT_PORT) -> Error:
	if state != State.OFFLINE:
		return ERR_ALREADY_IN_USE
	address = address.strip_edges()
	if address.is_empty():
		return ERR_INVALID_PARAMETER
	var peer := transport.join(address, port)
	if peer == null:
		return transport.last_error
	multiplayer.multiplayer_peer = peer
	_remote_peers.clear()
	state = State.JOINING
	_join_attempt += 1
	_start_join_timeout(_join_attempt)
	return OK

## Leave (client) or shut down (host) the session. Safe to call when offline.
func leave_session(reason: String = "left session") -> void:
	if state == State.OFFLINE:
		return
	_teardown(reason)

func _teardown(reason: String) -> void:
	var peer := multiplayer.multiplayer_peer
	if peer != null:
		peer.close()
	# Back to Godot's default offline peer so is_multiplayer_authority() and
	# friends keep behaving as they do in single-player.
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_remote_peers.clear()
	state = State.OFFLINE
	session_ended.emit(reason)

func _start_join_timeout(attempt: int) -> void:
	await get_tree().create_timer(JOIN_TIMEOUT_SEC).timeout
	if state == State.JOINING and attempt == _join_attempt:
		_teardown("join timed out")

#endregion

#region Multiplayer signal handlers

func _on_peer_connected(id: int) -> void:
	if state == State.HOSTING and get_player_count() >= MAX_PLAYERS:
		# ENet's max_clients already enforces this; kept as a transport-agnostic
		# backstop since a future relay transport may not.
		multiplayer.multiplayer_peer.disconnect_peer(id)
		return
	if id not in _remote_peers:
		_remote_peers.append(id)
	player_joined.emit(id)

func _on_peer_disconnected(id: int) -> void:
	_remote_peers.erase(id)
	player_left.emit(id)

func _on_connected_to_server() -> void:
	state = State.JOINED
	session_started.emit(false)

func _on_connection_failed() -> void:
	if state == State.JOINING:
		_teardown("connection failed")

func _on_server_disconnected() -> void:
	if state != State.OFFLINE:
		_teardown("host disconnected")

#endregion
