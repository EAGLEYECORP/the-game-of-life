class_name VehicleLights
extends Node
## Headlights, tail/brake lights, taxi roof sign and alarm flashing.
##
## Add as a child of a Vehicle. It finds its parts by name under the vehicle:
##   Body/Headlight*  lamp meshes at the front (glow when lights are on)
##   Body/Taillight*  red lamp meshes at the back (glow when on, brighter braking)
##   Body/TaxiSign*   roof sign meshes (lit whenever the lights are on)
##   HeadlightBeam*   SpotLight3D nodes that actually light the road
## Lamps on the left (+X) side are "left"; VehicleDamage can break each side.

const HEAD_OFF := Color(0.55, 0.55, 0.5)
const HEAD_ON := Color(1.0, 0.96, 0.82)
const TAIL_OFF := Color(0.35, 0.03, 0.03)
const TAIL_ON := Color(0.9, 0.05, 0.05)

@onready var _vehicle: Vehicle = get_parent()

var _head_mats := {}        # "left"/"right" -> StandardMaterial3D
var _tail_mat: StandardMaterial3D
var _sign_mat: StandardMaterial3D
var _beams := {}            # "left"/"right" -> Array[SpotLight3D]
var _broken := {"left": false, "right": false}


func _ready() -> void:
	_tail_mat = _lamp_material(TAIL_OFF)
	_sign_mat = _lamp_material(Color(0.85, 0.85, 0.8))
	for side in ["left", "right"]:
		_head_mats[side] = _lamp_material(HEAD_OFF)
		_beams[side] = []

	for mesh in _vehicle.find_children("Headlight*", "MeshInstance3D", true, false):
		mesh.material_override = _head_mats[_side_of(mesh)]
	for mesh in _vehicle.find_children("Taillight*", "MeshInstance3D", true, false):
		mesh.material_override = _tail_mat
	for mesh in _vehicle.find_children("TaxiSign*", "MeshInstance3D", true, false):
		mesh.material_override = _sign_mat
	for beam in _vehicle.find_children("HeadlightBeam*", "SpotLight3D", true, false):
		_beams[_side_of(beam)].append(beam)
		beam.visible = false


func _process(_delta: float) -> void:
	var flash := _vehicle.is_alarm_beat()
	var on := _vehicle.lights_on or flash

	for side in ["left", "right"]:
		var lit: bool = on and not _broken[side]
		_set_glow(_head_mats[side], HEAD_ON if lit else HEAD_OFF, 3.0 if lit else 0.0)
		for beam: SpotLight3D in _beams[side]:
			# The alarm only flashes the lamps, it doesn't light the street.
			beam.visible = lit and _vehicle.lights_on

	var tail_energy := 0.0
	if _vehicle.is_braking and _vehicle.has_driver():
		tail_energy = 4.0
	elif on:
		tail_energy = 1.5
	_set_glow(_tail_mat, TAIL_ON if tail_energy > 0.0 else TAIL_OFF, tail_energy)
	_set_glow(_sign_mat, Color(1, 1, 0.9) if on else Color(0.85, 0.85, 0.8), 2.0 if on else 0.0)


## Called by VehicleDamage on a hard front hit.
func break_headlight(side: String) -> void:
	_broken[side] = true


func repair() -> void:
	_broken = {"left": false, "right": false}


func _side_of(node: Node3D) -> String:
	var local := _vehicle.to_local(node.global_position)
	return "left" if local.x >= 0.0 else "right"


func _lamp_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 0.0
	return m


func _set_glow(m: StandardMaterial3D, color: Color, energy: float) -> void:
	m.albedo_color = color
	m.emission = color
	m.emission_energy_multiplier = energy
