extends Node
class_name FloorReplicator
## Sends the host's generated floor layout to clients (TGM-36, M1d, architecture D17).
##
## Only the host rolls the floor ([method GameFloor.roll_floor_layout]); it then hands the result to
## [method publish], which sends it to every connected client and keeps it so a client that joins
## later gets it too. A client builds a [GameFloor] replica from the payload and never draws from
## [RNG] for layout.
##
## Lives under [code]SceneLoader.persistent_node[/code] so it survives scene changes and sits at the
## same node path on every peer (RPCs need that). Call [method ensure] on EVERY peer before the
## session starts, the same rule as [PlayerSpawner].
##
## Out of scope for M1 (left for later milestones): battle contents, cogs, items, floor modifiers /
## anomalies, and anything a room scene rolls for itself when it is instantiated.

## Client only: the host's floor arrived and was built.
signal floor_received(payload: Dictionary)

const NODE_NAME := &"FloorReplicator"
const REQUIRED_KEYS: Array[String] = [
	"floor_number", "floor_name", "room_count", "level_range",
	"room_paths", "room_types", "music", "battle_music",
]

## Host: the layout of the live floor (re-sent to late joiners). Client: the layout last received.
var current_payload: Dictionary = {}
## Client only: a payload that arrived before the session finished connecting.
var _pending_payload: Dictionary = {}
## The floor this node started (host) or built (client), so a session ending can take it down.
var _floor: GameFloor
## Scene to go back to when the session ends mid-floor.
var _return_scene_path := ""
## Draws a small always-on-top status label; the session test rig turns it on.
var debug_overlay := false
var _overlay_label: Label

## Returns the replicator, creating it under the persistent node if needed.
static func ensure() -> FloorReplicator:
	var existing := SceneLoader.persistent_node.get_node_or_null(NodePath(NODE_NAME)) as FloorReplicator
	if existing:
		return existing
	var replicator := FloorReplicator.new()
	replicator.name = NODE_NAME
	SceneLoader.persistent_node.add_child(replicator)
	return replicator

func _ready() -> void:
	Session.player_joined.connect(_on_player_joined)
	Session.session_started.connect(_on_session_started)
	Session.session_ended.connect(_on_session_ended)
	Util.s_floor_ended.connect(_on_floor_ended)

func _process(_delta: float) -> void:
	_update_overlay()

#region Queries

## Client connected to a host but no floor has arrived yet.
func is_waiting_for_floor() -> bool:
	return Session.state == Session.State.JOINED and not is_instance_valid(_floor)

func has_floor() -> bool:
	return is_instance_valid(_floor)

#endregion

#region Host

## Host only. Starts a floor with [param floor_variant] and, in a session, replicates it.
## Remembers the current scene so ending the session can return to it.
func start_floor(floor_variant: FloorVariant) -> void:
	if not Session.is_host():
		push_warning("FloorReplicator.start_floor() ignored: only the host starts a floor.")
		return
	_remember_return_scene()
	var game_floor: GameFloor = load("res://scenes/game_floor/game_floor.tscn").instantiate()
	game_floor.floor_variant = floor_variant
	_floor = game_floor
	SceneLoader.change_scene_to_node(game_floor)

## Host only, called by [GameFloor] once it has rolled its layout. Sends it to every client that
## is connected now; [method _on_player_joined] covers the ones that connect later.
func publish(payload: Dictionary) -> void:
	if not Session.is_session_active() or not Session.is_host():
		return
	current_payload = payload
	for peer_id in multiplayer.get_peers():
		_send_to(peer_id)

func _send_to(peer_id: int) -> void:
	_receive_floor.rpc_id(peer_id, current_payload)

func _on_player_joined(peer_id: int) -> void:
	# On a client this also fires for the host and for other clients; only the host sends.
	if not Session.is_session_active() or not Session.is_host():
		return
	if current_payload.is_empty():
		return
	_send_to(peer_id)

#endregion

#region Client

## Reliable, because a lost layout leaves the client with no floor at all. The default RPC mode
## would be unreliable.
@rpc("authority", "call_remote", "reliable")
func _receive_floor(payload: Dictionary) -> void:
	if multiplayer.get_remote_sender_id() != Session.HOST_PEER_ID:
		return
	if not _is_valid_payload(payload):
		push_error("FloorReplicator: ignoring malformed floor payload from host.")
		return
	_pending_payload = payload
	_try_build_floor()

func _on_session_started(as_host: bool) -> void:
	# A client only counts as connected after session_started(false) (TGM-38), so a payload that
	# raced ahead of it waits here.
	if not as_host:
		_try_build_floor()

func _try_build_floor() -> void:
	if _pending_payload.is_empty() or Session.state != Session.State.JOINED:
		return
	var payload := _pending_payload
	_pending_payload = {}
	if not is_instance_valid(_floor):
		_remember_return_scene()
	current_payload = payload
	# change_scene_to_node() frees whatever scene is current, including a previous replica.
	_floor = GameFloor.create_replica(payload)
	SceneLoader.change_scene_to_node(_floor)
	floor_received.emit(payload)

func _is_valid_payload(payload: Dictionary) -> bool:
	for key in REQUIRED_KEYS:
		if not payload.has(key):
			return false
	var paths: PackedStringArray = payload["room_paths"]
	var types: PackedInt32Array = payload["room_types"]
	if paths.is_empty() or paths.size() != types.size():
		return false
	for path in paths:
		if not ResourceLoader.exists(path):
			push_error("FloorReplicator: host sent a room this build does not have: %s" % path)
			return false
	return true

#endregion

#region Session and floor lifecycle

func _on_floor_ended() -> void:
	# The floor is over: a peer that joins now should not be sent its layout.
	current_payload = {}
	_floor = null

## The session closing mid-floor takes the floor down on both roles. A client has lost its only
## source of floor state; a host that stops hosting goes back to where it started, since this
## milestone has no hand-off of a hosted floor to single-player.
func _on_session_ended(_reason: String) -> void:
	_pending_payload = {}
	current_payload = {}
	var had_floor := is_instance_valid(_floor)
	_floor = null
	if not had_floor:
		return
	# Clear the global refs first: the floor and the bodies are about to be freed.
	Util.floor_manager = null
	if not _return_scene_path.is_empty():
		SceneLoader.change_scene_to_file(_return_scene_path)
	_return_scene_path = ""

func _remember_return_scene() -> void:
	var current := SceneLoader.current_scene
	if is_instance_valid(current) and not current.scene_file_path.is_empty():
		_return_scene_path = current.scene_file_path

#endregion

#region Debug overlay

func _update_overlay() -> void:
	if not debug_overlay:
		return
	if not is_instance_valid(_overlay_label):
		var layer := CanvasLayer.new()
		layer.layer = 100
		add_child(layer)
		_overlay_label = Label.new()
		_overlay_label.position = Vector2(12, 12)
		layer.add_child(_overlay_label)
	var text := "Floor replication: "
	if is_instance_valid(_floor):
		# "first 5" is comparable between peers however far each has walked; "all built" is only
		# comparable when the built counts match.
		text += "%s | rooms built %d of %d planned | layout (first 5) %s | layout (all built) %s" % [
			"host" if Session.is_host() else "client",
			_floor.room_order.size(), _floor.room_plan_paths.size(),
			_floor.get_layout_fingerprint(5), _floor.get_layout_fingerprint()]
		text += "\nStreaming: " + _floor.get_stream_debug()
	elif is_waiting_for_floor():
		text += "waiting for host's floor"
	else:
		text += "no floor"
	_overlay_label.text = text

#endregion
