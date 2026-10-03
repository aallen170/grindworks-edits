extends Node3D
class_name GameFloor

enum RoomType {
	ENTRANCE,
	OBSTACLE,
	BATTLE,
	CONNECTOR,
	ONE_TIME,
	PRE_FINAL,
	BOSS,
}

const ROOM_REPEAT_DETECTION_SIZE := 3
const ANOMALY_TRACKER := preload("res://objects/general_ui/anomaly_tracker/anomaly_tracker.tscn")
const INTERACTIVE_STREAM_PLAYER := "res://scenes/game_floor/music_controller/facility_music_controller.tscn"

## The Floor Variant to be loaded into.
@export var floor_variant: FloorVariant
## Override for the amount of rooms to generate on the floor.
## -1 will make the room count based on the FloorVariant's value.
@export var room_count: int = -1
## Cog Level Range for the floor.
@export var level_range := Vector2i(1,12)
## Cog Spawning Pool.
@export var cog_pool: CogPool

# Floor generation tracking
## The amount of rooms to have in the Scene Tree at a time.
@export var render_rooms: int = 5
@onready var room_node := $Rooms
var unloaded_rooms: Node3D
var room_order: Array[StoredRoom] = []
## The LOCAL toon's room (TGM-41). Everything that asks "the current room" (items, music, out of
## bounds) means the local player. Streaming uses [method get_stream_anchors] instead, which also
## covers the other toons in a session.
var room_index := 0
## The anchor room indexes the loaded window was last built for, and whether a refresh is queued.
var _applied_anchors: Array[int] = []
var _refresh_queued := false
var floor_rooms: DepartmentFloor
var battle_ratio: float = 0.5
var rooms_remaining: Array[int] = []
var one_time_room_indexes: Array[int] = []
var previous_rooms: Array[FacilityRoom] = []
var interactive_music_player: Node

## Simplified method of storing custom values on the floor
var floor_tags: Dictionary[String, Variant] = {}

## Pre-rolled room plan (TGM-36, D17). Parallel arrays: scene path and RoomType per room, in
## floor order. The host (and single-player) rolls the whole plan up front in
## [method roll_room_plan]; a client receives it from the host and never draws from RNG for layout.
var room_plan_paths := PackedStringArray()
var room_plan_types := PackedInt32Array()
## Set on a client before _ready() by [method create_replica]: the layout the host sent.
## Empty on the host and in single-player.
var replicated_layout: Dictionary = {}
## Background track picked for this floor (path), so a client plays the host's choice.
var music_path := ""


class StoredRoom:
	var room: Node3D
	var room_transform: Transform3D
	var room_type: RoomType
# Signals
signal s_floor_ended

# Misc.
@onready var environment: WorldEnvironment = $WorldEnvironment

var anomalies: Array[FloorModifier] = []

# Debug
var debug_modifiers: Array[Script]
var debug_anomalies: Array[Script]
var debug_floor_variant: FloorVariant

func _init() -> void:
	EngineDebugger.register_message_capture('toonlike', _capture_debug_message)
	EngineDebugger.send_message('toonlike:ready_for', ['game_floor'])

func _ready() -> void:
	floor_variant.load_all()
	unloaded_rooms = Node3D.new()
	Util.floor_manager = self
	if is_replica():
		# The host already settled the count and the floor number.
		Util.floor_number = replicated_layout["floor_number"]
	else:
		# Room count must be an odd number
		if room_count % 2 == 0:
			room_count += 1
		Util.floor_number += 1
	if Session.is_session_active() and not is_instance_valid(Util.get_player()):
		# During a session toons come from the PlayerSpawner, and this peer's body may not have
		# arrived yet (a late joiner). Wait for it rather than spawning a second, wrongly-owned toon.
		Util.s_player_assigned.connect(func(_player: Player) -> void: generate_floor(), CONNECT_ONE_SHOT)
	else:
		generate_floor()
	if SaveFileService.run_file:
		SaveFileService.run_file.floor_choice = null
	if floor_variant.dynamic_music:
		interactive_music_player = load(INTERACTIVE_STREAM_PLAYER).instantiate()
		interactive_music_player.interactive_stream = floor_variant.dynamic_music
		add_child(interactive_music_player)

## True on a client building the host's floor. Everything random was already decided by the host.
func is_replica() -> bool:
	return not replicated_layout.is_empty()

## Builds a GameFloor from the layout a host sent (see [method build_layout_payload]).
## A stand-in FloorVariant carries only what the floor reads while building: the host's floor
## variant lost its resource identity when it was duplicated and randomized, and anomalies,
## modifiers and rewards are not part of the M1 payload.
static func create_replica(layout: Dictionary) -> GameFloor:
	var new_floor: GameFloor = load("res://scenes/game_floor/game_floor.tscn").instantiate()
	var variant := FloorVariant.new()
	variant.floor_name = layout["floor_name"]
	variant.floor_type = DepartmentFloor.new()
	variant.floor_type.battle_music = layout["battle_music"]
	new_floor.floor_variant = variant
	new_floor.room_count = layout["room_count"]
	new_floor.level_range = layout["level_range"]
	new_floor.room_plan_paths = layout["room_paths"]
	new_floor.room_plan_types = layout["room_types"]
	new_floor.music_path = layout["music"]
	new_floor.replicated_layout = layout
	return new_floor

## What a client needs to rebuild this floor's layout. Plain Variants only (it travels over RPC).
func build_layout_payload() -> Dictionary:
	return {
		"floor_number": Util.floor_number,
		"floor_name": floor_variant.floor_name,
		"room_count": room_count,
		"level_range": level_range,
		"room_paths": room_plan_paths,
		"room_types": room_plan_types,
		"music": music_path,
		"battle_music": floor_rooms.battle_music,
	}

## Order-sensitive hash of the rooms built so far: scene, type and placement. Two peers that built
## the same rooms print the same value. Pass [param max_rooms] to hash only the first N rooms, so
## peers that have walked different distances can still be compared.
func get_layout_fingerprint(max_rooms := -1) -> String:
	var parts: Array = []
	for i in room_order.size():
		if max_rooms >= 0 and i >= max_rooms:
			break
		var stored := room_order[i]
		var room_pos: Vector3 = stored.room_transform.origin
		parts.append([stored.room.scene_file_path, stored.room_type, snappedf(room_pos.x, 0.01), snappedf(room_pos.y, 0.01), snappedf(room_pos.z, 0.01)])
	return "%08x" % (hash(parts) & 0xffffffff)

func generate_floor() -> void:
	if debug_floor_variant:
		floor_variant = debug_floor_variant
	if not floor_variant:
		push_error("Failed to generate floor: No floor variant specified.")
		return
	
	# Get floor difficulty values from room variant
	# Setting value to anything else will let you debug custom sizes
	if room_count == -1:
		room_count = floor_variant.room_count
		level_range = floor_variant.level_range
		cog_pool = floor_variant.cog_pool
	
	# Add reward to seen_items
	if floor_variant.discard_item:
		ItemService.seen_item(floor_variant.discard_item)
	
	# Set up floor modifiers (debug anomalies set below)
	for modifier in floor_variant.modifiers + debug_modifiers:
		initialize_floor_mod(modifier)

	if Util.floor_number == 0:
		$LocationText.set_text("Ground Floor\n%s" % floor_variant.floor_name)
	else:
		$LocationText.set_text("Floor %d\n%s" % [Util.floor_number, floor_variant.floor_name])
	
	# Some values may be copied over from the floor variant to the floor type
	floor_variant.floor_type = floor_variant.floor_type.duplicate(true)
	if floor_variant.room_pack:
		inject_room_pack(floor_variant.floor_type, floor_variant.room_pack)
	
	# Get the floor room values
	floor_rooms = floor_variant.floor_type
	Util.floor_type = floor_rooms
	if not is_replica():
		roll_floor_layout()
		music_path = ""
		if not floor_rooms.background_music.is_empty():
			music_path = floor_rooms.background_music[randi() % floor_rooms.background_music.size()]
		if Session.is_session_active() and Session.is_host():
			FloorReplicator.ensure().publish(build_layout_payload())
	
	var player := Util.get_player()
	if not player:
		player = load("res://objects/player/player.tscn").instantiate()
		SceneLoader.add_persistent_node(player)
	player.s_fell_out_of_world.connect(player_out_of_bounds)
	
	# Setup debug anomalies
	for modifier in debug_anomalies:
		var new_mod := initialize_floor_mod(modifier)
		if new_mod:
			anomalies.append(new_mod)
	
	# Generate random rooms
	for i in render_rooms:
		if i >= room_count:
			break
		add_random_room()
		if i == 0:
			spawn_player(player)
	
	# Start anomaly tracker now that we've gotten all our anomalies
	if not anomalies.is_empty():
		show_anomalies()
	
	if Util.floor_number == 0:
		player.fall_in(true)
		player.game_timer_tick = true
	else:
		player.teleport_in(true)
	if Util.window_focused:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	# Set the proper default bg music
	if not music_path.is_empty():
		AudioManager.set_default_music(load(music_path))

func spawn_player(player: Player) -> void:
	var entrance = room_node.get_child(0)
	var spawn_point: Node3D = entrance.get_node('SPAWNPOINT')
	player.global_position = spawn_point.global_position
	player.current_room_index = 0
	# Each peer places only its own body (position syncs from the owner); spread them along the
	# spawn point so toons do not stack inside each other.
	var spawn_index := maxi(Session.get_player_peer_ids().find(Session.get_local_peer_id()), 0)
	player.global_position += spawn_point.global_transform.basis.x * (spawn_index * PlayerSpawner.SPAWN_SPACING)
	player.state = Player.PlayerState.WALK
	player.camera.make_current()
	player.face_position(entrance.get_node('EXIT').global_position)
	player.recenter_camera(true)

func get_random_connector_room() -> PackedScene:
	return load(get_random_connector_room_path())

func get_random_connector_room_path() -> String:
	return RNG.channel(&'connector_rooms').pick_random(floor_rooms.connectors)

func inject_room_pack(dept_floor: DepartmentFloor, room_pack: RoomPack) -> void:
	var room_types: Dictionary[String, String] = {
		'entrances': 'entrance_mode',
		'battle_rooms': 'battle_mode',
		'obstacle_rooms': 'obstacle_mode',
		'connectors': 'connector_mode',
		'pre_final_rooms': 'pre_final_mode',
		'final_rooms': 'final_mode',
		'one_time_rooms': 'one_time_mode',
	}
	for room_type in room_types.keys():
		if room_pack.get(room_types[room_type]) == RoomPack.PackMode.REPLACE:
			dept_floor.set(room_type, room_pack.get(room_type))
		else:
			var rooms: Array = dept_floor.get(room_type)
			rooms.append_array(room_pack.get(room_type))
			dept_floor.set(room_type, rooms)

## Rolls everything about the floor's shape that is random (host and single-player only).
func roll_floor_layout() -> void:
	# Randomly decide 40% - 60% battle rooms
	battle_ratio = 0.4 + (0.1 * float(RNG.channel(RNG.ChannelBattleRatio).randi() % 3))
	var total_rooms = int((room_count - 2) / 2)
	var total_battles := int(total_rooms * battle_ratio)
	rooms_remaining = [total_battles, total_rooms - total_battles]

	if floor_rooms.special_rooms and RNG.channel(RNG.ChannelRoomLogic).randf() < get_special_room_chance():
		# 50% chance to add a "special room" to the pool
		var sr_idx := RNG.channel(RNG.ChannelRoomLogic).randi_range(1, floor_rooms.special_rooms.size()) - 1
		print('Adding special room: %s' % floor_rooms.special_rooms[sr_idx].room)
		floor_rooms.one_time_rooms.append(floor_rooms.special_rooms[sr_idx].room)

	# Add 2 rooms to the floor per 1 time room
	# And get a room index to slap that room into
	for i in floor_rooms.one_time_rooms.size():
		room_count += 2
		var rand_room := -1
		while rand_room * 2 in one_time_room_indexes or rand_room == -1:
			rand_room = RNG.channel(RNG.ChannelRoomLogic).randi() % (room_count - 1) / 2
			# Ensure 0 cannot be rolled
			rand_room = maxi(rand_room,1)
		one_time_room_indexes.append(rand_room * 2)

	roll_room_plan()

## Rolls every room of the floor up front, in the same order the old lazy generation drew them, so
## each RNG channel sees the same sequence as before. The plan is what gets replicated (D17).
func roll_room_plan() -> void:
	room_plan_paths.clear()
	room_plan_types.clear()
	while true:
		var index := room_plan_paths.size()
		if index == 0:
			var entrance: String = floor_rooms.entrances[RNG.channel(RNG.ChannelRoomLogic).randi() % floor_rooms.entrances.size()]
			plan_room(entrance, RoomType.ENTRANCE)
		elif index in one_time_room_indexes:
			plan_room(floor_rooms.one_time_rooms[one_time_room_indexes.find(index)], RoomType.ONE_TIME)
		elif index < room_count - 1:
			if index % 2 == 0:
				# Roll a random room type based on the remaining rooms
				var room_roll := RNG.channel(RNG.ChannelRemainingRooms).randi() % (rooms_remaining[0] + rooms_remaining[1])
				if room_roll < rooms_remaining[0]:
					plan_room(roll_for_room_path(floor_rooms.battle_rooms, 'battle_rooms'), RoomType.BATTLE)
					rooms_remaining[0] -= 1
				else:
					plan_room(roll_for_room_path(floor_rooms.obstacle_rooms, 'obstacle_rooms'), RoomType.OBSTACLE)
					rooms_remaining[1] -= 1
			else:
				plan_room(get_random_connector_room_path(), RoomType.CONNECTOR)
		else:
			if floor_rooms.pre_final_rooms:
				plan_room(roll_for_room_path(floor_rooms.pre_final_rooms, 'pre_final_rooms'), RoomType.PRE_FINAL)
				plan_room(get_random_connector_room_path(), RoomType.CONNECTOR)
			plan_room(roll_for_room_path(floor_rooms.final_rooms, 'boss_rooms'), RoomType.BOSS)
			return

func plan_room(path: String, room_type: RoomType) -> void:
	room_plan_paths.append(path)
	room_plan_types.append(room_type)

## Builds the next room from the plan. The pre-final room, its connector and the boss room go in
## together, as they always have.
func add_random_room() -> void:
	var index := room_order.size()
	if index >= room_plan_paths.size():
		return
	append_planned_room(index)
	match room_plan_types[index]:
		RoomType.PRE_FINAL:
			append_planned_room(index + 1)
			append_planned_room(index + 2)
			render_rooms += 1
		RoomType.BOSS:
			render_rooms += 1

func append_planned_room(index: int) -> void:
	append_room(load(room_plan_paths[index]), room_plan_types[index] as RoomType)

func append_room(room: PackedScene, room_type: RoomType):
	var new_module: Node3D = room.instantiate()
	room_node.add_child(new_module)
	new_module.name = str(room_order.size())
	# For all rooms except the entrance, do some tricky math to attach them 
	if not room_order.is_empty():
		var prev_room = room_order[room_order.size() - 1].room
		var prev_exit = prev_room.get_node('EXIT')
		var new_entrance = new_module.get_node('ENTRANCE')
		
		# Failsafe!
		if not prev_room.is_inside_tree():
			prev_room.reparent(room_node)
		
		# Rotate the new room
		var rot = prev_room.global_rotation.y
		new_module.rotation.y = rot
		new_module.rotation.y += prev_exit.rotation.y + new_entrance.rotation.y
	
		# Get reference info
		var entrance_pos = new_entrance.position
		var entrance_global_pos = new_entrance.global_position
		
		# Place new entrance on previous exit
		new_entrance.global_position = prev_exit.global_position
		
		# Get difference between entrance's old and new positions
		var pos_diff = new_entrance.global_position - entrance_global_pos
		
		# Apply the difference to the new module
		new_module.global_position += pos_diff
		
		# Reset entrance node pos
		new_entrance.position = entrance_pos
		
		# For doorways mostly
		if not new_entrance.visible or not prev_exit.visible:
			new_entrance.hide()
			prev_exit.hide()
	
	# Connect the body entered signal from the room to adjust the room renders
	new_module.get_node('RoomArea').body_entered.connect(body_entered_room.bind(room_order.size()))
	new_module.get_node('RoomArea').collision_mask = Globals.PLAYER_COLLISION_LAYER
	
	# Add a new stored room to the room_order array
	var storage := StoredRoom.new()
	storage.room = new_module
	storage.room_transform = new_module.transform
	storage.room_type = room_type
	room_order.append(storage)

func body_entered_room(body, index: int):
	# Only the local toon moves the local room_index. A remote body fires this too (it overlaps the
	# RoomArea), but its room arrives through Player.current_room_index, which also covers a room
	# this peer has not built or has unloaded, where no Area signal can fire (TGM-41).
	if body is Player and body.is_multiplayer_authority():
		room_index = index
		body.current_room_index = index
		adjust_view(index)

func roll_for_room(rooms: Array[FacilityRoom], seed_channel := RNG.ChannelTrueRandom) -> PackedScene:
	return load(roll_for_room_path(rooms, seed_channel))

func roll_for_room_path(rooms: Array[FacilityRoom], seed_channel := RNG.ChannelTrueRandom) -> String:
	rooms = rooms.duplicate(true)
	for room in previous_rooms:
		if room in rooms:
			rooms.erase(room)
	
	var weights : Array[float] = []
	for room in rooms:
		weights.append(room.rarity_weight)
	
	var room_idx := RNG.channel(seed_channel).rand_weighted(weights)
	if previous_rooms.size() >= ROOM_REPEAT_DETECTION_SIZE:
		previous_rooms.pop_front()
	previous_rooms.append(rooms[room_idx])
	return rooms[room_idx].room

## Queues a streaming refresh, run at the start of the next physics frame by [method _physics_process].
## Queued and coalesced: [method body_entered_room] runs inside a physics callback, and reparenting
## rooms (which hold the very RoomAreas that are signalling) from there is unsafe; several toons
## entering rooms in one frame also only need one pass. A physics frame, not an idle one
## ([code]call_deferred[/code]): rooms hold interpolated cameras, and moving them outside the physics
## frame logs "[Physics interpolation] Interpolated Camera3D triggered from outside physics process".
func adjust_view(_index: int = 0) -> void:
	_refresh_queued = true

## Room indexes to keep loaded windows around: the local toon's room, plus the room of every
## other toon in the session (read from the replicated [member Player.current_room_index]).
## A toon whose body has not arrived yet is skipped. A disconnected toon's body is kept alive
## (D5), so its room stays loaded.
func get_stream_anchors() -> Array[int]:
	var anchors: Array[int] = [room_index]
	if not Session.is_session_active():
		return anchors
	var spawner := PlayerSpawner.find()
	if not spawner:
		return anchors
	var local_id := Session.get_local_peer_id()
	for peer_id in Session.get_player_peer_ids():
		if peer_id == local_id:
			continue
		var body := spawner.get_body(peer_id)
		if body:
			anchors.append(clampi(body.current_room_index, 0, maxi(room_count - 1, 0)))
	return anchors

## A remote toon's room changes arrive over the network, with no signal on this peer, so poll.
## Cheap: at most four ints compared per physics frame, and only during a session.
func _physics_process(_delta: float) -> void:
	if room_order.is_empty():
		return
	if _refresh_queued:
		_refresh_streaming()
	elif Session.is_session_active() and get_stream_anchors() != _applied_anchors:
		_refresh_streaming()

## One-line summary for the debug overlay (TGM-41): which room each toon is in (local first), and
## which room indexes are currently in the tree on this peer.
func get_stream_debug() -> String:
	var loaded: Array[int] = []
	for i in room_order.size():
		if room_order[i].room.is_inside_tree():
			loaded.append(i)
	return "toon rooms %s | loaded rooms %s" % [get_stream_anchors(), loaded]

func _refresh_streaming() -> void:
	_refresh_queued = false
	if room_order.is_empty():
		return
	var anchors := get_stream_anchors()
	_applied_anchors = anchors
	var border := render_rooms / 2

	# Keep a room loaded if ANY toon's window covers it, so no room unloads out from under a toon.
	for i in room_order.size():
		var room = room_order[i].room
		var wanted := false
		for anchor in anchors:
			# Same window as single-player always used for one anchor.
			if i >= maxi(anchor - border, 0) and i <= maxi(anchor + border, render_rooms):
				wanted = true
				break
		if not wanted:
			if room.get_parent() == room_node:
				room.reparent(unloaded_rooms)
		else:
			if not room.is_inside_tree():
				room.reparent(room_node, false)
				room.transform = room_order[i].room_transform

	# Build forward until the furthest anchor has rooms planned around it. This is a target, not
	# a per-step increment: a toon that is several rooms past what was built still gets a full window.
	var build_target := 0
	for anchor in anchors:
		build_target = maxi(build_target, mini(anchor + border, room_count - 1))
	while room_order.size() - 1 < build_target:
		var built := room_order.size()
		add_random_room()
		if room_order.size() == built:
			# Nothing left in the plan; do not spin.
			break

func get_current_room() -> Node3D:
	return room_order[room_index].room

func get_current_room_type() -> RoomType:
	var stored_room := room_order[room_index]
	if stored_room.room_type:
		return stored_room.room_type
	return RoomType.CONNECTOR

func _notification(what):
	# Free unloaded rooms when scene is being freed
	if what == NOTIFICATION_PREDELETE:
		unloaded_rooms.queue_free()
		EngineDebugger.unregister_message_capture('toonlike')

func player_out_of_bounds(player : Player) -> void:
	var entrance_node: Node3D
	if get_current_room().has_node('SPAWNPOINT'):
		entrance_node = get_current_room().get_node('SPAWNPOINT')
	else:
		entrance_node = get_current_room().get_node('ENTRANCE')
	player.global_position = entrance_node.global_position
	player.fall_in(true)

func initialize_floor_mod(modifier : Script) -> FloorModifier:
	var new_mod := Node.new()
	new_mod.set_script(modifier)
	if new_mod is FloorModifier:
		$Modifiers.add_child(new_mod)
		new_mod.initialize(self)
		new_mod.set_name(new_mod.get_mod_name())
		if modifier in floor_variant.anomalies:
			anomalies.append(new_mod)
		return new_mod
	return null

func show_anomalies(new_anomalies : Array[FloorModifier] = anomalies) -> void:
	var tracker := ANOMALY_TRACKER.instantiate()
	tracker.anomalies = new_anomalies
	add_child(tracker)
	tracker.play()

func spawn_new_anomalies(count : int) -> Array[FloorModifier]:
	var new_anomalies : Array[FloorModifier] = []
	for i in count:
		var new_anomaly := floor_variant.get_new_anomaly()
		if new_anomaly:
			var anomaly_node := initialize_floor_mod(new_anomaly)
			new_anomalies.append(anomaly_node)
			anomalies.append(anomaly_node)
			if not Util.get_player().obscured_anomalies:
				Util.get_player().boost_queue.queue_text(anomaly_node.get_mod_name(), anomaly_node.text_color)
			Util.get_player().stats.stranger_chance += Util.get_player().stats.stranger_chance_per_anomaly
	return new_anomalies

func remove_anomaly(anomaly : FloorModifier) -> void:
	if anomaly in anomalies:
		anomaly.clean_up()
		anomalies.erase(anomaly)
		floor_variant.anomalies.erase(anomaly.get_script())
		anomaly.queue_free()

func get_special_room_chance() -> float:
	var luck := 1.0
	var base_chance := 0.12
	if is_instance_valid(Util.get_player()):
		luck = Util.get_player().stats.luck
	return base_chance + (luck - 1.0)

func _capture_debug_message(message: String, data: Array) -> bool:
	if message == 'game_floor:add_floor_mods':
		var anomalies_list = (
			FloorVariant.ANOMALIES_POSITIVE +
			FloorVariant.ANOMALIES_NEUTRAL +
			FloorVariant.ANOMALIES_NEGATIVE
		)
		for modifier in data:
			if modifier in anomalies_list:
				debug_anomalies.append(load(modifier))
			else:
				debug_modifiers.append(load(modifier))
		return true
	elif message == 'game_floor:set_floor_variant':
		debug_floor_variant = load(data[0])
	return false

#region GAME TRACKING
## Game Signals
signal s_cog_spawned(cog: Cog)
#endregion
