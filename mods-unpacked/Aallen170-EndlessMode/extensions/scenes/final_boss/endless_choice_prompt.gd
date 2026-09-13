extends CanvasLayer

# TGM-8: minimal end-run/keep-going prompt for Endless Mode, shown after the
# player beats the boss on any Executive Office floor.
#
# Deliberately just a plain two-button popup for now - built entirely in
# code so there's no .tscn to keep in sync. Andrew's got plans for a real
# two-elevator choice (different doors/triggers) later; this is just enough
# to test the underlying suppress-victory-sequence / loop-vs-end logic.

signal s_choice_made(end_run: bool)


func _ready() -> void:
	layer = 100
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 32)
	margin.add_theme_constant_override("margin_right", 32)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	margin.add_child(vbox)

	var label := Label.new()
	label.text = "You beat the Executive Office!\nEnd the run here, or keep going?"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(label)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 24)
	vbox.add_child(hbox)

	var keep_going_button := Button.new()
	keep_going_button.text = "Keep Going"
	keep_going_button.pressed.connect(_on_choice.bind(false))
	hbox.add_child(keep_going_button)

	var end_run_button := Button.new()
	end_run_button.text = "End Run"
	end_run_button.pressed.connect(_on_choice.bind(true))
	hbox.add_child(end_run_button)

	keep_going_button.grab_focus()


func _on_choice(end_run: bool) -> void:
	s_choice_made.emit(end_run)
	queue_free()
