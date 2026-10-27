class_name HUD
extends CanvasLayer
## On-screen overlay: interaction hint, speedometer and a controls cheat sheet.

@onready var _hint: Label = $Hint
@onready var _speedo: Label = $Speedometer
@onready var _controls: Label = $Controls

## Vehicle shown on the speedometer, or null when on foot.
var _vehicle: Vehicle = null

const FOOT_CONTROLS := "WASD move  ·  Shift run  ·  Space jump  ·  E enter car\nMouse look  ·  C reset camera  ·  Esc free mouse"
const CAR_CONTROLS := "W/S throttle & brake  ·  A/D steer  ·  Space handbrake\nE exit car  ·  Mouse look  ·  C reset camera"


func _ready() -> void:
	set_hint("")
	show_vehicle(null)


func _process(_delta: float) -> void:
	if _vehicle:
		_speedo.text = "%d km/h" % roundi(_vehicle.get_speed_kmh())


func set_hint(text: String) -> void:
	_hint.text = text
	_hint.visible = text != ""


## Switches the HUD between on-foot and driving layouts.
func show_vehicle(vehicle: Vehicle) -> void:
	_vehicle = vehicle
	_speedo.visible = vehicle != null
	_controls.text = CAR_CONTROLS if vehicle else FOOT_CONTROLS
