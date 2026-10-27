class_name HUD
extends CanvasLayer
## On-screen overlay: interaction hint, speedometer, vehicle condition and a
## controls cheat sheet.

@onready var _hint: Label = $Hint
@onready var _speedo: Label = $Speedometer
@onready var _vehicle_info: Label = $VehicleInfo
@onready var _controls: Label = $Controls
@onready var _district: Label = $District
@onready var _notice: Label = $Notice
@onready var _attribution: Label = $Attribution

## Vehicle shown on the speedometer, or null when on foot.
var _vehicle: Vehicle = null

const FOOT_CONTROLS := "WASD move  ·  Shift run  ·  Space jump  ·  F enter / steal vehicle\nMouse look  ·  C reset camera  ·  Esc free mouse"
const CAR_CONTROLS := "W/S throttle & brake  ·  A/D steer  ·  Space handbrake  ·  H horn  ·  L lights\nF get out  ·  Mouse look  ·  C reset camera"


func _ready() -> void:
	set_hint("")
	show_vehicle(null)
	set_district("")
	set_notice("")
	set_attribution("")


func _process(_delta: float) -> void:
	if _vehicle:
		_speedo.text = "%d km/h" % roundi(_vehicle.get_speed_kmh())
		var damage := _vehicle.get_node_or_null("Damage") as VehicleDamage
		var condition := "" if damage == null else "  ·  condition %d%%" % roundi(damage.condition)
		_vehicle_info.text = _vehicle.display_name + condition


func set_hint(text: String) -> void:
	_hint.text = text
	_hint.visible = text != ""


## Switches the HUD between on-foot and driving layouts.
func show_vehicle(vehicle: Vehicle) -> void:
	_vehicle = vehicle
	_speedo.visible = vehicle != null
	_vehicle_info.visible = vehicle != null
	_controls.text = CAR_CONTROLS if vehicle else FOOT_CONTROLS


## Current neighbourhood ("Old Medina", ...). Empty hides it.
func set_district(text: String) -> void:
	_district.text = text


## Centre-top message, e.g. while the map loads.
func set_notice(text: String) -> void:
	_notice.text = text
	_notice.visible = text != ""


## Data credit. OpenStreetMap's licence (ODbL) requires showing it.
func set_attribution(text: String) -> void:
	_attribution.text = text
