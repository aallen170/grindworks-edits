extends MultiplayerSpawner
class_name PlayerSpawner
## Spawns one replicated toon body per session peer (TGM-37, M1c).
##
## Lives under [code]SceneLoader.persistent_node[/code], so toons survive scene
## changes and the node path is identical on every peer (a spawner has to be at
## the same path everywhere). Call [method ensure] on EVERY peer before the
## session starts: a client that has no spawner at that path cannot receive the
## host's spawn packets.
##
## Only the host spawns (TGM-38 note): on a client [signal Session.player_joined]
## fires for the host and for every other client, so spawning from it would make
## every peer spawn every toon. Spawned bodies replicate to everyone, including
## late joiners, through the spawner itself.
##
## Each body is owned by its own peer ([code]set_multiplayer_authority(peer_id)[/code]
## in [method _spawn_player], before the node enters the tree on every peer). A
## remote peer leaving does NOT free its body (D5: the host keeps a disconnected
## toon alive); bodies are only freed when the session itself ends.

## Emitted on every peer for every body this spawner creates, just before the
## body enters the tree. Spawn-time hook for the local-body setup the caller
## owns (camera.make_current(), initial state, ...).
signal player_spawned(player: Player, peer_id: int)

const PLAYER_SCENE_PATH := "res://objects/player/player.tscn"
const NODE_NAME := &"PlayerSpawner"
## Spacing between toons at spawn, so bodies don't stack inside each other.
const SPAWN_SPACING := 2.0

## peer_id -> body, on every peer. Entries can go stale if a body is freed
## elsewhere, so read through [method get_body].
var _bodies: Dictionary[int, Player] = {}

## Returns the spawner, creating it under the persistent node if needed.
static func ensure() -> PlayerSpawner:
	var existing := SceneLoader.persistent_node.get_node_or_null(NodePath(NODE_NAME)) as PlayerSpawner
	if existing:
		return existing
	var spawner := PlayerSpawner.new()
	spawner.name = NODE_NAME
	SceneLoader.persistent_node.add_child(spawner)
	return spawner

func _ready() -> void:
	# Spawned bodies are added as siblings of the spawner, under the persistent node.
	spawn_path = NodePath("..")
	spawn_function = _spawn_player
	Session.session_started.connect(_on_session_started)
	Session.player_joined.connect(_on_player_joined)
	Session.session_ended.connect(_on_session_ended)
	# The spawner may be created after the session is already live.
	if Session.is_session_active():
		_on_session_started(Session.is_host())

func get_body(peer_id: int) -> Player:
	var body: Player = _bodies.get(peer_id)
	return body if is_instance_valid(body) else null

## Host only. Spawns the toon for [param peer_id] unless it already exists.
func spawn_player(peer_id: int) -> Player:
	if not Session.is_session_active() or not Session.is_host():
		return null
	if get_body(peer_id):
		return get_body(peer_id)
	var index := maxi(Session.get_player_peer_ids().find(peer_id), 0)
	return spawn({"peer_id": peer_id, "index": index}) as Player

## Runs on every peer (the host calls it from spawn(), clients from the spawn
## packet), so everything here has to be deterministic from [param data].
func _spawn_player(data: Variant) -> Node:
	var peer_id: int = data["peer_id"]
	var body: Player = load(PLAYER_SCENE_PATH).instantiate()
	body.name = "Player_%d" % peer_id
	body.position = Vector3(float(data["index"]) * SPAWN_SPACING, 1.0, 0.0)
	# The synchronizer has to exist before authority is assigned: the recursive
	# set_multiplayer_authority() below only reaches nodes that already exist.
	body.setup_network_sync()
	# Before the node enters the tree, or player.gd's _enter_tree() builds the
	# camera/HUD for the wrong peer (or for nobody).
	body.set_multiplayer_authority(peer_id)
	_bodies[peer_id] = body
	player_spawned.emit(body, peer_id)
	return body

func _on_session_started(as_host: bool) -> void:
	if not as_host:
		return
	# The host's own toon is not a player_joined event: spawn it explicitly with authority 1.
	for peer_id in Session.get_player_peer_ids():
		spawn_player(peer_id)

func _on_player_joined(peer_id: int) -> void:
	if Session.is_host():
		spawn_player(peer_id)

func _on_session_ended(_reason: String) -> void:
	# Spawned bodies belong to the session. M1d decides whether the host's own
	# toon should instead be handed back to the single-player path.
	for body in _bodies.values():
		if is_instance_valid(body):
			body.queue_free()
	_bodies.clear()
