## The game's input actions, added in code: a resource pack mounted in
## another Godot project brings no project settings (and so no input map),
## so the game defines what it needs when it starts.
extends RefCounted

const ACTIONS := {
	"move_forward": [KEY_W, KEY_UP],
	"move_back": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"jump": [KEY_SPACE],
	"sprint": [KEY_SHIFT],
	"reload": [KEY_R],
}


static func ensure() -> void:
	for action in ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)
		for key in ACTIONS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			if not InputMap.action_has_event(action, ev):
				InputMap.action_add_event(action, ev)
	_mouse("fire", MOUSE_BUTTON_LEFT)
	_mouse("aim", MOUSE_BUTTON_RIGHT)
	_pad("fire", JOY_AXIS_TRIGGER_RIGHT)
	_pad("aim", JOY_AXIS_TRIGGER_LEFT)
	_stick("move_left", JOY_AXIS_LEFT_X, -1.0)
	_stick("move_right", JOY_AXIS_LEFT_X, 1.0)
	_stick("move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_stick("move_back", JOY_AXIS_LEFT_Y, 1.0)
	_button("jump", JOY_BUTTON_A)
	_button("reload", JOY_BUTTON_X)
	_button("sprint", JOY_BUTTON_LEFT_STICK)


static func _mouse(action: String, button: MouseButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	if not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)


static func _pad(action: String, axis: JoyAxis) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = 1.0
	if not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)


static func _stick(action: String, axis: JoyAxis, value: float) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	if not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)


static func _button(action: String, button: JoyButton) -> void:
	var ev := InputEventJoypadButton.new()
	ev.button_index = button
	if not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)
