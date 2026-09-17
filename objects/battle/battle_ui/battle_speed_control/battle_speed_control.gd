extends CanvasLayer
class_name BattleSpeedControl

## Always-visible in-battle control for adjusting battle speed, mirroring the
## settings menu's speed slider (SaveFileService.settings_file.battle_speed).
## Lives outside BattleUI's CanvasLayer so it stays on screen even while
## BattleUI is hidden during round resolution, which is exactly when
## adjusting speed is most useful.

@onready var speed_slider: HSlider = %SpeedSlider
@onready var speed_label: Label = %SpeedLabel

@onready var manager: BattleManager = get_parent()

func _ready() -> void:
	speed_slider.value = SaveFileService.settings_file.battle_speed
	refresh_label()
 
func _exit_tree() -> void:
	# Safety net: this control is torn down along with the rest of the battle
	# (it's a child of BattleManager, freed when the battle ends), so make
	# sure Engine.time_scale can never be left stuck above 1.0 once the
	# battle is actually over, even if it was pushed there live mid-round.
	#
	# Debug tooling: Globals.debug_persist_timescale (toggled via the
	# "persist_timescale" dev console command) skips this reset too, so it
	# doesn't undo the same carry-over battle_manager.gd's
	# revert_battle_speed() is meant to skip.
	if Globals.debug_persist_timescale:
		return
	Engine.time_scale = 1.0

func set_speed(value: float) -> void:
	SaveFileService.settings_file.battle_speed = value
	SaveFileService.save_settings()
	refresh_label()

	# If a round is currently playing out, apply the new speed immediately
	# instead of waiting for the next round's apply_battle_speed() call.
	if manager and manager.is_round_ongoing:
		Engine.time_scale = SaveFileService.settings_file.battle_speed

func refresh_label() -> void:
	speed_label.text = get_speed_string(SaveFileService.settings_file.battle_speed)

func get_speed_string(speed: float) -> String:
	var text := "x%.2f" % speed
	if text.ends_with("00"): text = text.trim_suffix("0")
	return text
