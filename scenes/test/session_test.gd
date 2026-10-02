extends Control

## Manual test rig for TGM-38 (M1b session layer). Placeholder UI only, no lobby.
##
## Two instances on one machine: in the Godot editor use
## Debug > Customize Run Instances... (enable multiple instances), set this scene as
## the run scene (F6 on it runs one instance only), then Host in one window and Join
## 127.0.0.1 in the other. Both instances share user://, but this scene never reads
## or writes it (D9/D15), so that is safe here.
##
## Acceptance to check by eye:
##   1. Both windows show the same "Host peer id" and the correct role.
##   2. Closing the client window logs "player left" on the host; the host keeps running.
##   3. A 5th instance joining is refused (cap of 4).
##
## TGM-37 (M1c) additions: the scene also has a flat test floor and a PlayerSpawner
## (created on every instance before any session starts, which spawners require).
## Once connected, each window should show its own toon with a camera and HUD plus
## the other player's toon, and moving in one window should move that toon in the
## other. Check:
##   4. Both toons are visible in both windows, standing apart.
##   5. WASD in one window moves only that window's toon; the other window shows
##      the same toon moving (position, facing, walk/run/jump animation).
##   6. Each window has exactly one camera and one HUD, and only the focused
##      window's input moves anything.
## Walking captures the mouse, so Host/Join first. Do not press Esc (the pause menu
## is not loaded in this scene); close the window to leave.

var _role_label := Label.new()
var _players_label := Label.new()
var _log := RichTextLabel.new()
var _address := LineEdit.new()
var _port := LineEdit.new()
var _spawner: PlayerSpawner

func _ready() -> void:
	_build_test_floor()
	_spawner = PlayerSpawner.ensure()
	_spawner.player_spawned.connect(_on_player_spawned)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 16)
	add_child(root)

	var row := HBoxContainer.new()
	root.add_child(row)
	var host_btn := Button.new()
	host_btn.text = "Host"
	host_btn.pressed.connect(_on_host_pressed)
	row.add_child(host_btn)
	_address.placeholder_text = "Host IP"
	_address.text = "127.0.0.1"
	_address.custom_minimum_size.x = 200
	row.add_child(_address)
	_port.text = str(Session.DEFAULT_PORT)
	_port.custom_minimum_size.x = 80
	row.add_child(_port)
	var join_btn := Button.new()
	join_btn.text = "Join"
	join_btn.pressed.connect(_on_join_pressed)
	row.add_child(join_btn)
	var leave_btn := Button.new()
	leave_btn.text = "Leave"
	leave_btn.pressed.connect(func() -> void: Session.leave_session())
	row.add_child(leave_btn)

	root.add_child(_role_label)
	root.add_child(_players_label)
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	root.add_child(_log)

	Session.session_started.connect(func(as_host: bool) -> void:
		_say("session started (as_host=%s)" % as_host))
	Session.session_ended.connect(func(reason: String) -> void:
		_say("session ended: %s" % reason))
	Session.player_joined.connect(func(id: int) -> void: _say("player joined: %d" % id))
	Session.player_left.connect(func(id: int) -> void: _say("player left: %d" % id))
	_refresh()

func _process(_delta: float) -> void:
	_refresh()

## Flat floor + light. Physics layer 1 is in the Player's collision mask.
func _build_test_floor() -> void:
	var world := Node3D.new()
	world.name = "TestWorld"
	add_child(world)
	var floor_body := StaticBody3D.new()
	floor_body.position = Vector3(4, -0.5, 0)
	world.add_child(floor_body)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	shape.shape = box
	floor_body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = box.size
	mesh.mesh = box_mesh
	floor_body.add_child(mesh)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, 30, 0)
	world.add_child(light)

func _on_player_spawned(body: Player, peer_id: int) -> void:
	# Compare peer ids rather than body.is_multiplayer_authority(): this signal
	# fires before the body enters the tree, and that check is always false for
	# a node that is not in the tree yet.
	var is_local := peer_id == Session.get_local_peer_id()
	_say("spawned toon for peer %d (local: %s)" % [peer_id, is_local])
	if not is_local:
		return
	# Local toon only: take the camera and start walking once the body is ready.
	body.ready.connect(_start_local_body.bind(body), CONNECT_ONE_SHOT)

func _start_local_body(body: Player) -> void:
	body.camera.make_current()
	body.state = Player.PlayerState.WALK

func _port_value() -> int:
	return _port.text.to_int() if _port.text.is_valid_int() else Session.DEFAULT_PORT

func _on_host_pressed() -> void:
	var err := Session.host_session(_port_value())
	_say("host_session -> %s" % error_string(err))

func _on_join_pressed() -> void:
	var err := Session.join_session(_address.text, _port_value())
	_say("join_session -> %s" % error_string(err))

func _refresh() -> void:
	_role_label.text = "State: %s | is_host(): %s | local peer id: %d | host peer id: %d" % [
		Session.State.keys()[Session.state], Session.is_host(),
		Session.get_local_peer_id(), Session.HOST_PEER_ID]
	_players_label.text = "Players (%d/%d): %s" % [
		Session.get_player_count(), Session.MAX_PLAYERS, Session.get_player_peer_ids()]

func _say(text: String) -> void:
	print("[SessionTest] ", text)
	_log.append_text(text + "\n")
