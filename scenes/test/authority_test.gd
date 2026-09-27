extends Node3D

## Manual test rig for TGM-39's acceptance criterion: "a second body can be
## instantiated locally without a duplicate camera or HUD."
##
## There's no real networking in this project yet (TGM-37/out of scope for
## TGM-39), so this exercises the same is_multiplayer_authority() gate a
## remote-owned body would hit, without needing an actual MultiplayerPeer:
## forcing a node's multiplayer authority to a different peer id before it
## enters the tree makes is_multiplayer_authority() return false for it,
## exactly as it would for a real remote player's body.
##
## Run this scene (F6) and check the on-screen label / Output panel for
## PASS or FAIL.

const PLAYER_SCENE: PackedScene = preload("res://objects/player/player.tscn")

func _ready() -> void:
	var results: Array[String] = []

	# "Local" body -- default multiplayer authority (1). This is the same
	# default every node gets offline/single-player, and matches every
	# other Player instance in the game.
	var local_player: Player = PLAYER_SCENE.instantiate()
	local_player.name = "LocalPlayer"
	local_player.position = Vector3(-2, 0, 0)
	add_child(local_player)

	# "Remote" body -- authority forced to peer id 2 *before* add_child().
	# player.gd's _enter_tree() reads is_multiplayer_authority() the instant
	# the node enters the tree, so this has to be set beforehand -- setting
	# it after add_child() would be too late and would defeat the test.
	var remote_player: Player = PLAYER_SCENE.instantiate()
	remote_player.name = "RemotePlayer"
	remote_player.set_multiplayer_authority(2, true)
	remote_player.position = Vector3(2, 0, 0)
	add_child(remote_player)

	var local_has_camera := local_player.has_node("PlayerCamera")
	var local_has_gui := local_player.has_node("GUI")
	var remote_has_camera := remote_player.has_node("PlayerCamera")
	var remote_has_gui := remote_player.has_node("GUI")

	results.append("LocalPlayer  (authority=1, is_multiplayer_authority=true)  -> camera=%s gui=%s  (expect true/true)" % [local_has_camera, local_has_gui])
	results.append("RemotePlayer (authority=2, is_multiplayer_authority=false) -> camera=%s gui=%s  (expect false/false)" % [remote_has_camera, remote_has_gui])
	results.append("")

	var passed := local_has_camera and local_has_gui and not remote_has_camera and not remote_has_gui
	results.append("RESULT: %s" % ("PASS - no duplicate camera/HUD for the non-authority body" if passed else "FAIL - see TGM-39"))

	for line in results:
		print(line)

	if has_node("CanvasLayer/ResultLabel"):
		$CanvasLayer/ResultLabel.text = "\n".join(results)
