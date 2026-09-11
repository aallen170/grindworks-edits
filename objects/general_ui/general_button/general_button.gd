@tool
extends TextureButton
class_name GeneralButton

@export var press_sfx: AudioStream
@export var hover_sfx: AudioStream
@export var hover_db_offset := 6.0
@export var press_db_offset := 0.0
@export_multiline var text := "":
	set(x):
		_text = x
		if is_node_ready():
			$Label.text = x
	get:
		return _text
@export var font_size: float:
	set(x):
		_font_size = x
		if is_node_ready():
			$Label.label_settings.font_size = x
	get:
		return _font_size

var _text := ""
var _font_size := 0.0

func _ready() -> void:
	$Label.text = _text
	if _font_size > 0.0:
		$Label.label_settings.font_size = _font_size

func on_button_down() -> void:
	if press_sfx:
		AudioManager.play_sound(press_sfx, press_db_offset)

func on_mouse_entered() -> void:
	if hover_sfx:
		AudioManager.play_sound(hover_sfx, hover_db_offset)
