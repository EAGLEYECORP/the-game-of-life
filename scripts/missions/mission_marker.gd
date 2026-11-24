class_name MissionMarker
extends Node3D
## A glowing column of light on the ground, GTA style: mission starts,
## objectives, race checkpoints and the garage. Purely visual; the mission
## manager checks distances itself (no physics areas needed).

const COLORS := {
	"mission": Color(1.0, 0.82, 0.2),     # Yellow: start a story mission.
	"objective": Color(1.0, 0.85, 0.25),  # Where to go now.
	"checkpoint": Color(0.3, 0.75, 1.0),  # Race checkpoint.
	"garage": Color(0.4, 1.0, 0.5),       # Youssef's garage.
	"taxi": Color(1.0, 0.25, 0.2),        # Taxi pickup / drop-off.
}

var radius := 3.0
var _beam: MeshInstance3D
var _ring: MeshInstance3D
var _label: Label3D
var _t := 0.0


## `kind` picks the colour (see COLORS); `letter` floats above it (e.g. "Y").
static func create(parent: Node, pos: Vector3, kind: String, letter := "", radius_m := 3.0) -> MissionMarker:
	var m := MissionMarker.new()
	m.radius = radius_m
	parent.add_child(m)
	m.global_position = pos
	m._build(COLORS.get(kind, Color.YELLOW), letter)
	return m


func _build(color: Color, letter: String) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(color.r, color.g, color.b, 0.28)
	var beam := CylinderMesh.new()
	beam.top_radius = radius * 0.9
	beam.bottom_radius = radius
	beam.height = 2.2
	beam.cap_top = false
	beam.cap_bottom = false
	beam.material = mat
	_beam = MeshInstance3D.new()
	_beam.mesh = beam
	_beam.position.y = 1.1
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_beam)

	var ring_mat := mat.duplicate() as StandardMaterial3D
	ring_mat.albedo_color = Color(color.r, color.g, color.b, 0.7)
	var ring := TorusMesh.new()
	ring.inner_radius = radius - 0.15
	ring.outer_radius = radius
	ring.material = ring_mat
	_ring = MeshInstance3D.new()
	_ring.mesh = ring
	_ring.position.y = 0.08
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)

	if letter != "":
		_label = Label3D.new()
		_label.text = letter
		_label.font = CitySigns.font()
		_label.font_size = 96
		_label.pixel_size = 0.01
		_label.modulate = color
		_label.outline_size = 12
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.no_depth_test = false
		_label.position.y = 3.2
		add_child(_label)


func _process(delta: float) -> void:
	_t += delta
	_ring.scale = Vector3.ONE * (1.0 + 0.05 * sin(_t * 3.0))
	if _label:
		_label.position.y = 3.2 + 0.15 * sin(_t * 2.0)


## Horizontal distance check (markers sit on the ground).
func contains(pos: Vector3) -> bool:
	return Vector2(pos.x - global_position.x, pos.z - global_position.z).length() <= radius
