extends Object

# TGM-8: Endless Mode hook for penthouse_boss.gd - suppress the vanilla
# victory sequence on Endless Mode boss loops, and let the player choose to
# end the run or keep going.
#
# Two separate vanilla things fire unconditionally on every boss kill,
# looping or not:
#
# 1. battle_ending() - connected to the battle manager's s_battle_ending
#    signal, fires BEFORE the victory-dance animation even plays. Stops the
#    run timer, reveals the seed label (game_timer.become_full_visible()),
#    and records best_time / checks the one-hour-win achievement.
#
# 2. on_battle_finished() - connected (in penthouse.tscn, not code) to
#    BattleNode's s_battle_end signal, fires AFTER the victory-dance. Runs
#    the toon-unlock logic and then win_game(), the ~20-30s cage-rescue
#    cinema (cage lowering, caged-toon dialogue, camera pans, walk to
#    elevator, fade to black) which itself calls end_game() at the very end.
#
# Fix: skip battle_ending()'s vanilla body entirely on any boss floor - we
# don't know yet whether this is a real ending. At on_battle_finished() -
# after the victory-dance, before the unlock logic / cinematic - show a
# simple end-run/keep-going prompt:
#   - End Run: replay battle_ending()'s real effects (now that we know it's
#     a real ending), then let vanilla on_battle_finished() run unmodified
#     (unlock + win_game() + end_game() - the real, one-time ending).
#   - Keep Going: skip all of it (no unlock, no cinematic, no timer/seed
#     reveal) and do the same silent loop-back the old end_game() hook used
#     to do. Because this can now run multiple times in one run, the
#     partner-freeing loop is guarded with is_instance_valid() and the
#     array is cleared afterward, so a later loop doesn't iterate over
#     already-freed Node references from an earlier one.
#
# This replaces the old end_game() hook entirely - the loop-back logic now
# lives in on_battle_finished()'s "keep going" branch below, so end_game()
# itself no longer needs to be touched at all.

const EndlessChoicePrompt := preload("res://mods-unpacked/Aallen170-EndlessMode/extensions/scenes/final_boss/endless_choice_prompt.gd")


func battle_ending(chain: ModLoaderHookChain) -> void:
	if Util.floor_number < 5:
		# Shouldn't happen outside the boss floor - don't touch vanilla flow.
		chain.execute_next([])
		return
	# Otherwise: skip vanilla's timer-lock / seed-reveal / best_time /
	# achievement check. Replayed manually in on_battle_finished() below,
	# only if the player ends up choosing to end the run.


func on_battle_finished(chain: ModLoaderHookChain) -> void:
	if Util.floor_number < 5:
		# Shouldn't happen outside the boss floor - don't touch vanilla flow.
		chain.execute_next([])
		return

	var boss: FinalBossScene = chain.reference_object

	var prompt := EndlessChoicePrompt.new()
	boss.add_child(prompt)
	var end_run: bool = await prompt.s_choice_made

	if end_run:
		apply_battle_ending_effects()
		chain.execute_next([])
		return

	# Keep going: silent loop-back, same as the old end_game() hook used to
	# do - no cinematic, no toon unlock, no timer/seed reveal, no wins/streak
	# bump (those only happen through the real end_game() -> s_game_win path,
	# which we're deliberately not calling here).
	var player := Util.get_player()
	for partner in player.partners:
		if is_instance_valid(partner):
			partner.queue_free()
	player.partners.clear()

	# TGM-11: ToonTasks used to go blank after a boss loop because
	# barrel_room.gd's clear_quests() ran unconditionally on every boss-floor
	# entry. That's now fixed at the source in barrel_room.hooks.gd (which
	# skips clear_quests() entirely so the player's existing ToonTasks and
	# their progress carry straight through the fight), so nothing needs to
	# happen here anymore - no quest list to refill.

	# TGM-17: ItemService.seen_items never gets cleared past character
	# creation (item_service.gd's on_floor_end() - wired up to fire every
	# floor - is an empty stub; reset() only runs on a full save-file reset).
	# Once every item in a pool has been seen, get_random_item() falls back
	# to the roll-fail pool forever, which is what "runs dry" after enough
	# floors. Per Andrew (2026-09-16): rather than clearing every floor
	# (which would let duplicates show up even before the first boss) or
	# never within a run (the reported bug), duplicates should only become
	# possible once a boss floor has actually been cleared - so the pool
	# stays exhausted-once-seen for a normal 5-floor run, and resets on each
	# Endless Mode loop rather than piling up seen items across the whole
	# run. Clearing here (once per boss defeated, only on "keep going") is
	# the natural hook point for that.
	ItemService.seen_items.clear()

	Util.floor_number += 1
	if SaveFileService.run_file:
		SaveFileService.run_file.floor_choice = null
	SceneLoader.change_scene_to_file('res://scenes/elevator_scene/elevator_scene.tscn')


## Vanilla penthouse_boss.gd's battle_ending(), replayed here once we know
## the player actually chose to end the run. Keep in sync with vanilla if it
## ever changes.
func apply_battle_ending_effects() -> void:
	var player := Util.get_player()
	player.game_timer_tick = false
	player.lock_game_timer = true
	player.game_timer.become_full_visible()
	var win_time: float = player.game_timer.time
	if win_time < 3600.0:
		Globals.s_one_hour_win.emit()
	if win_time < SaveFileService.progress_file.best_time or is_equal_approx(0.0, SaveFileService.progress_file.best_time):
		SaveFileService.progress_file.best_time = player.game_timer.time

