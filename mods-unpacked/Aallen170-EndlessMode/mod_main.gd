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
