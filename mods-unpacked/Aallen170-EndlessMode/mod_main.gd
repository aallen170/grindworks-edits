extends Node

# TGM-6: Endless Mode
# ! MVP scope: no in-game settings toggle. Enabling/disabling this mod via the
# ! game's built-in Settings > Mods list *is* the on/off switch - when this mod
# ! is active, defeating the floor-5 boss loops back to the elevator with
# ! scaling difficulty forever, instead of ending the run.

const MOD_DIR := "Aallen170-EndlessMode"
const LOG_NAME := "Aallen170-EndlessMode:Main"

var mod_dir_path := ""
var extensions_dir_path := ""


func _init() -> void:
	mod_dir_path = ModLoaderMod.get_unpacked_dir().path_join(MOD_DIR)
	install_script_hook_files()


func install_script_hook_files() -> void:
	extensions_dir_path = mod_dir_path.path_join("extensions")
	ModLoaderMod.install_script_hooks(
		"res://scenes/elevator_scene/elevator_scene.gd",
		extensions_dir_path.path_join("scenes/elevator_scene/elevator_scene.hooks.gd")
	)
	ModLoaderMod.install_script_hooks(
		"res://scenes/final_boss/penthouse_boss.gd",
		extensions_dir_path.path_join("scenes/final_boss/penthouse_boss.hooks.gd")
	)
	# TGM-11: keeps the player's existing ToonTasks (and their progress) intact
	# across a boss loop instead of being cleared and restocked - see
	# barrel_room.hooks.gd for why.
	ModLoaderMod.install_script_hooks(
		"res://scenes/final_boss/barrel_room.gd",
		extensions_dir_path.path_join("scenes/final_boss/barrel_room.hooks.gd")
	)
	# TGM-9: scales boss cogs (and their mid-fight reinforcements) with the
	# same curve the boss floor's own level_range uses, instead of the fixed
	# DNA-preset level they fell back to. See cog.hooks.gd for the root cause.
	ModLoaderMod.install_script_hooks(
		"res://objects/cog/cog.gd",
		extensions_dir_path.path_join("objects/cog/cog.hooks.gd")
	)
	# TGM-11 follow-up: QuestCog.randomize_objective() indexes
	# FloorVariant.LEVEL_RANGES (keys 0-5 only) directly by Util.floor_number,
	# which crashes the moment a ToonTask is rerolled/completed on any floor
	# past the first boss loop - see quest_cog.hooks.gd for the root cause.
	ModLoaderMod.install_script_hooks(
		"res://objects/quests/types/quest_cog.gd",
		extensions_dir_path.path_join("objects/quests/types/quest_cog.hooks.gd")
	)
	# TGM-9 follow-up (2026-09-13): floor_variant.hooks.gd already existed
	# (written as part of TGM-6/7's original normal-floor scaling curve) but
	# was never actually registered here, so floor_variant.gd's own vanilla
	# get_calculated_level_range() - the "I will not be testing how well
	# balanced this is" exploding failsafe - kept running for every normal
	# floor past floor 5 the whole time. That's why cogs on floor 7 (the
	# first normal floor after the first boss) were still scaling far past
	# what the player had built up for. Wiring this up applies the intended
	# linear curve there too.
	ModLoaderMod.install_script_hooks(
		"res://scenes/game_floor/floor_variants/floor_variant.gd",
		extensions_dir_path.path_join("scenes/game_floor/floor_variants/floor_variant.hooks.gd")
	)
