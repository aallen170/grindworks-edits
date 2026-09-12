extends Object

# TGM-6: Endless Mode hook for penthouse_boss.gd
#
# TEMP DEBUG BUILD: has extra print() calls added at each step so we can see
# exactly where the floor-7 freeze happens. Remove these once the bug is
# found and fixed.
#
# Vanilla behavior: end_game() sends the player to the win_menu scene,
# ending the run. It also frees any active partners (e.g. the Mystery Toon's
# allies) but never clears Player.partners itself - fine in vanilla, since
# the run ends immediately afterward and this code never runs a second time.
#
# Endless behavior: loop back to the elevator instead, with the floor
# counter advanced (mirroring what game_floor.gd normally does when
# entering a standard floor - the boss floor uses an override_scene, so it
# never goes through that increment itself) and the saved floor_choice
# cleared so elevator_scene.gd's "resume last choice" branch doesn't
# immediately re-trigger this same boss floor.
#
# Because our loop can now run this code multiple times in one run, we also
# guard the partner-freeing loop with is_instance_valid() and clear the
# array afterward - without this, a second win would iterate over
# already-freed Node references left over from the first win and call
# queue_free() on them again.


func end_game(chain: ModLoaderHookChain) -> void:
	print("[EndlessMode DEBUG] penthouse_boss.end_game start, floor_number=", Util.floor_number)
	if Util.floor_number < 5:
		# Shouldn't happen outside the boss floor - don't touch vanilla flow.
		print("[EndlessMode DEBUG] penthouse_boss.end_game floor_number < 5, deferring to vanilla")
		chain.execute_next([])
		return

	var boss: Node = chain.reference_object

	match Util.get_player().character.character_id:
		PlayerCharacter.Character.MYSTERY:
			if not SaveFileService.progress_file.mystery_toon_win:
				Globals.s_mystery_win.emit()
				SaveFileService.make_progress('mystery_toon_win', true)
	print("[EndlessMode DEBUG] penthouse_boss.end_game mystery check done")

	Globals.s_game_win.emit()
	print("[EndlessMode DEBUG] penthouse_boss.end_game s_game_win emitted")
	var player := Util.get_player()
	print("[EndlessMode DEBUG] penthouse_boss.end_game player.partners count=", player.partners.size())
	for partner in player.partners:
		if is_instance_valid(partner):
			partner.queue_free()
	player.partners.clear()
	print("[EndlessMode DEBUG] penthouse_boss.end_game partners cleared")

	# Continue the loop instead of ending the run.
	Util.floor_number += 1
	print("[EndlessMode DEBUG] penthouse_boss.end_game floor_number incremented to ", Util.floor_number)
	if SaveFileService.run_file:
		SaveFileService.run_file.floor_choice = null
	print("[EndlessMode DEBUG] penthouse_boss.end_game floor_choice cleared, about to change scene")
	SceneLoader.change_scene_to_file('res://scenes/elevator_scene/elevator_scene.tscn')
	print("[EndlessMode DEBUG] penthouse_boss.end_game change_scene_to_file returned")
