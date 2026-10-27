extends Node
## Registers every input action the game uses, at startup.
##
## Defining actions in code (instead of Project Settings > Input Map) keeps the
## bindings readable in one place and guarantees the project runs out of the box.
## If you define one of these actions yourself in the Input Map editor, your
## editor bindings win and the defaults below are skipped for that action.

# Action name -> list of keyboard keycodes / mouse buttons bound to it.
const KEY_BINDINGS := {
	"move_forward": [KEY_W, KEY_UP],
	"move_back": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"jump": [KEY_SPACE],          # On foot: jump.
	"sprint": [KEY_SHIFT],        # On foot: run.
	"interact": [KEY_F, KEY_E],   # Enter / exit (and steal) vehicles.
	"handbrake": [KEY_SPACE],     # In vehicle: handbrake.
	"horn": [KEY_H],              # In vehicle: horn.
	"toggle_lights": [KEY_L],     # In vehicle: headlights on/off.
	"camera_reset": [KEY_C],      # Snap camera behind the target.
	"toggle_mouse": [KEY_ESCAPE], # Release / capture the mouse cursor.
}

# Action name -> list of gamepad buttons bound to it.
const JOY_BUTTON_BINDINGS := {
	"jump": [JOY_BUTTON_A],
	"handbrake": [JOY_BUTTON_A],
	"sprint": [JOY_BUTTON_LEFT_STICK],
	"interact": [JOY_BUTTON_Y],
	"horn": [JOY_BUTTON_LEFT_SHOULDER],
	"toggle_lights": [JOY_BUTTON_DPAD_UP],
	"camera_reset": [JOY_BUTTON_RIGHT_STICK],
	"toggle_mouse": [JOY_BUTTON_START],
}

# Action name -> [axis, direction]. Left stick moves, triggers drive.
const JOY_AXIS_BINDINGS := {
	"move_forward": [[JOY_AXIS_LEFT_Y, -1.0], [JOY_AXIS_TRIGGER_RIGHT, 1.0]],
	"move_back": [[JOY_AXIS_LEFT_Y, 1.0], [JOY_AXIS_TRIGGER_LEFT, 1.0]],
	"move_left": [[JOY_AXIS_LEFT_X, -1.0]],
	"move_right": [[JOY_AXIS_LEFT_X, 1.0]],
	"look_left": [[JOY_AXIS_RIGHT_X, -1.0]],
	"look_right": [[JOY_AXIS_RIGHT_X, 1.0]],
	"look_up": [[JOY_AXIS_RIGHT_Y, -1.0]],
	"look_down": [[JOY_AXIS_RIGHT_Y, 1.0]],
}


# Actions that existed before this script ran (built-ins + Input Map editor).
var _preexisting: Array[StringName] = []


func _ready() -> void:
	_preexisting = InputMap.get_actions()

	for action: String in KEY_BINDINGS:
		if not _ensure_action(action):
			continue
		for keycode: Key in KEY_BINDINGS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = keycode
			InputMap.action_add_event(action, ev)

	for action: String in JOY_BUTTON_BINDINGS:
		if not _ensure_action(action):
			continue
		for button: JoyButton in JOY_BUTTON_BINDINGS[action]:
			var ev := InputEventJoypadButton.new()
			ev.button_index = button
			InputMap.action_add_event(action, ev)

	for action: String in JOY_AXIS_BINDINGS:
		if not _ensure_action(action):
			continue
		for binding: Array in JOY_AXIS_BINDINGS[action]:
			var ev := InputEventJoypadMotion.new()
			ev.axis = binding[0]
			ev.axis_value = binding[1]
			InputMap.action_add_event(action, ev)


## Creates the action if needed. Returns false when the action was defined in
## the Input Map editor, meaning our default bindings should not be added.
func _ensure_action(action: String) -> bool:
	if StringName(action) in _preexisting:
		return false
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.2)
	return true
