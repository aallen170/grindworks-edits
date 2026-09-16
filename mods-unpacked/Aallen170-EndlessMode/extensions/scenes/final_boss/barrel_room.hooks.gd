extends Object

# TGM-11 (revised 2026-09-16): the original fix restocked the quest list with
# fresh ToonTasks after an Endless Mode "keep going" loop (see
# penthouse_boss.hooks.gd's history), but Andrew wants the player's *existing*
# ToonTasks - including whatever progress had already been made on them - to
# carry straight through the boss fight instead of being wiped and replaced.
#
# barrel_room.gd's vanilla _ready() unconditionally calls
# `player.stats.clear_quests()` every time this scene loads, which is the
# boss floor's `override_scene` (see elevator_scene.gd's start_game_floor()).
# In vanilla that's fine - this scene is only ever entered once, right before
# the run-ending fight, so tidying up incomplete quests there doesn't lose
# anything the player still needed. In Endless Mode it's entered again on
# every boss loop, wiping in-progress ToonTasks each time.
#
# Nothing between here and the run actually ending reads player.stats.quests
# (score/quest-completion tracking is signal-driven via
# Globals.s_quest_completed, not read from the array), and a fresh PlayerStats
# is created for the next game regardless, so simply never clearing the quest
# list here doesn't break the true, one-time vanilla ending either - it just
# means an ending run keeps showing whatever ToonTasks were left, which
# doesn't matter once the run is over.
#
# Fix: skip vanilla's `clear_quests()` call entirely; keep everything else
# `_ready()` did (camera/position setup, the intro cinematic, and
# `clear_items_in_play()`, which only reads the quest list rather than
# depending on it having just been cleared).
#
# This makes the TGM-11 refill-after-restock approach in
# penthouse_boss.hooks.gd unnecessary - removed there in the same change.

func _ready(chain: ModLoaderHookChain) -> void:
	var barrel_room = chain.reference_object
	barrel_room.intro_camera.make_current()
	var player := Util.get_player()
	player.game_timer_tick = false
	player.global_position = barrel_room.entrance_elevator.player_pos.global_position
	player.toon.rotation_degrees.y = 180.0

	barrel_room.play_intro(player)

	Globals.s_entered_barrel_room.emit()

	barrel_room.clear_items_in_play(player.stats)
