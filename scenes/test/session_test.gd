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

var _role_label := Label.new()
var _players_label := Label.new()
var _log := RichTextLabel.new()
var _address := LineEdit.new()
var _port := LineEdit.new()

func _ready() -> void:
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
