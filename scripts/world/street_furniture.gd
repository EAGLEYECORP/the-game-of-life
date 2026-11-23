class_name StreetFurniture
extends Node3D
## Street lamps, street name plates and billboards around the player, placed
## from the road graph and streamed as you move.
##
## Performance:
##   - Lamp poles and lamp heads are two MultiMeshes: hundreds of lamps cost
##     two draw calls. The heads glow from a shader driven by the global
##     night_factor, so nothing is updated per lamp.
##   - Only the nearest `max_lights` lamps get a real OmniLight, and only at
##     night; the small pool of lights is moved to whichever lamps are closest.
##   - Plates and billboards are kept per junction / road and only the ones
##     entering or leaving the radius are created or freed.

@export var traffic: TrafficManager
@export var player: Node3D
@export var radius := 210.0              ## Lamps/billboards built within this range.
@export var plate_radius := 110.0        ## Street name plates within this range.
@export var rebuild_distance := 45.0     ## Re-place after moving this far.
@export var lamp_spacing := 32.0
@export var max_lights := 12
@export var light_range := 16.0

const LAMP_COLOR := Color(1.0, 0.74, 0.42)   # Warm sodium street light.

var _poles: MultiMeshInstance3D
var _heads: MultiMeshInstance3D
var _lamp_heads := PackedVector3Array()
var _lights: Array[OmniLight3D] = []
var _plates := {}      # node id -> Node3D
var _boards := {}      # edge id -> Node3D
var _center := Vector2.INF
var _light_timer := 0.0


func _ready() -> void:
	_poles = MultiMeshInstance3D.new()
	_poles.multimesh = _make_multimesh(_pole_mesh())
	add_child(_poles)
	_heads = MultiMeshInstance3D.new()
	_heads.multimesh = _make_multimesh(_head_mesh())
	_heads.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_heads)
	for i in max_lights:
		var l := OmniLight3D.new()
		l.light_color = LAMP_COLOR
		l.omni_range = light_range
		l.omni_attenuation = 1.2
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		_lights.append(l)


func _process(delta: float) -> void:
	if traffic == null or traffic.graph == null or player == null:
		return
	var p := Vector2(player.global_position.x, player.global_position.z)
	if _center == Vector2.INF or p.distance_to(_center) > rebuild_distance:
		_center = p
		_rebuild(traffic.graph, p)
	_light_timer -= delta
	if _light_timer <= 0.0:
		_light_timer = 0.3
		_update_lights(player.global_position)


func _rebuild(g: RoadGraph, center: Vector2) -> void:
	# Lamps: along every street, alternating sides, on the pavement.
	var taken := {}
	var heads := PackedVector3Array()
	var transforms: Array[Transform3D] = []
	for e in g.edges_near(center, radius):
		if not g.is_drivable(e):
			continue
		var pts := g.edge_points[e]
		var off := g.edge_width[e] * 0.5 + 0.9
		var along := lamp_spacing * 0.5
		var side := 1.0 if (e % 2) == 0 else -1.0
		while along < g.edge_length[e]:
			var p := g.point_along(e, along)
			var q := g.point_along(e, minf(along + 1.0, g.edge_length[e]))
			var dir := (q - p).normalized()
			if dir != Vector2.ZERO and p.distance_to(center) < radius:
				var right := Vector2(-dir.y, dir.x)
				var pos := p + right * off * side
				var cell := Vector2i((pos / 12.0).floor())
				if not taken.has(cell):
					taken[cell] = true
					# Pole faces the road: its arm reaches over the carriageway.
					var to_road := -right * side
					var basis := Basis(Vector3.UP, atan2(to_road.x, to_road.y))
					var t := Transform3D(basis, Vector3(pos.x, 0.0, pos.y))
					transforms.append(t)
					heads.append(t * Vector3(0, 6.1, 1.3))
			along += lamp_spacing
			side = -side
	_fill(_poles.multimesh, transforms)
	_fill(_heads.multimesh, transforms)
	_lamp_heads = heads

	# Street name plates at named junctions.
	var keep := {}
	for e in g.edges_near(center, plate_radius):
		for n in [g.edge_a[e], g.edge_b[e]]:
			if keep.has(n) or g.nodes[n].distance_to(center) > plate_radius:
				continue
			keep[n] = true
			if not _plates.has(n):
				_plates[n] = _build_plates(g, n)
	for n: int in _plates.keys():
		if not keep.has(n) and g.nodes[n].distance_to(center) > plate_radius + 30.0:
			if _plates[n]:
				_plates[n].queue_free()
			_plates.erase(n)

	# Billboards along main roads.
	var keep_b := {}
	for e in g.edges_near(center, radius):
		if g.edge_class[e] < 2 or g.edge_length[e] < 50.0 or hash(e) % 3 != 0:
			continue
		var mid := g.point_along(e, g.edge_length[e] * 0.5)
		if mid.distance_to(center) > radius:
			continue
		keep_b[e] = true
		if not _boards.has(e):
			_boards[e] = _build_billboard(g, e, mid)
	for e: int in _boards.keys():
		if not keep_b.has(e):
			_boards[e].queue_free()
			_boards.erase(e)


## Up to two plates at a junction, one per differently named street, each
## mounted parallel to the street it names, on the corner pavement.
func _build_plates(g: RoadGraph, n: int) -> Node3D:
	var done := {}
	var root: Node3D = null
	for e in g.node_edges[n]:
		var name_id := g.edge_name[e]
		if name_id < 0 or done.has(name_id) or not g.is_drivable(e) or done.size() >= 2:
			continue
		done[name_id] = true
		if root == null:
			root = Node3D.new()
			add_child(root)
		var pts := g.edge_points[e]
		var away := ((pts[1] - pts[0]) if g.edge_a[e] == n else (pts[-2] - pts[-1])).normalized()
		var right := Vector2(-away.y, away.x)
		var w := g.edge_width[e]
		var corner := g.nodes[n] + away * (w * 0.5 + 3.0) + right * (w * 0.5 + 1.2)
		var names: Array = g.names[name_id]
		CitySigns.street_plate(root, Vector3(corner.x, 0.0, corner.y), atan2(-away.y, away.x),
			names[0], names[1] if names.size() > 1 else "")
	return root


func _build_billboard(g: RoadGraph, e: int, mid: Vector2) -> Node3D:
	var q := g.point_along(e, g.edge_length[e] * 0.5 + 1.0)
	var dir := (q - mid).normalized()
	var right := Vector2(-dir.y, dir.x)
	var pos := mid + right * (g.edge_width[e] * 0.5 + 4.0)
	var root := Node3D.new()
	add_child(root)
	CitySigns.billboard(root, Vector3(pos.x, 0.0, pos.y), atan2(-right.x, -right.y), hash(e))
	return root


## Moves the light pool onto the nearest lamps at night.
func _update_lights(at: Vector3) -> void:
	var night := DayNightCycle.current.night_factor if DayNightCycle.current else 0.0
	if night < 0.15:
		for l in _lights:
			l.visible = false
		return
	var near: Array = []
	for h in _lamp_heads:
		var d := h.distance_squared_to(at)
		if d < 90.0 * 90.0:
			near.append([d, h])
	near.sort_custom(func(a, b): return a[0] < b[0])
	for i in _lights.size():
		var l := _lights[i]
		if i < near.size():
			l.visible = true
			l.global_position = near[i][1] - Vector3(0, 0.3, 0)
			l.light_energy = 1.6 * night
		else:
			l.visible = false


# --- Meshes ---------------------------------------------------------------------

func _make_multimesh(mesh: Mesh) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	return mm


func _fill(mm: MultiMesh, transforms: Array[Transform3D]) -> void:
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])


func _pole_mesh() -> Mesh:
	var grey := Color(0.28, 0.3, 0.3)
	return NpcVisuals.bake([
		[NpcVisuals._cyl(0.06, 0.1, 6.2), Transform3D(Basis(), Vector3(0, 3.1, 0)), grey, "shiny"],
		[NpcVisuals._box(Vector3(0.08, 0.08, 1.4)), Transform3D(Basis(), Vector3(0, 6.2, 0.65)), grey, "shiny"],
		[NpcVisuals._box(Vector3(0.36, 0.14, 0.6)), Transform3D(Basis(), Vector3(0, 6.18, 1.3)), Color(0.2, 0.2, 0.2), "matte"],
	])


## Lamp glass: glows warm at night through the global night_factor.
func _head_mesh() -> Mesh:
	var m := BoxMesh.new()
	m.size = Vector3(0.3, 0.06, 0.5)
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded;
global uniform float night_factor;
void fragment() {
	ALBEDO = mix(vec3(0.55, 0.55, 0.5), vec3(1.0, 0.74, 0.42) * 4.0, night_factor);
}
"""
	mat.shader = sh
	m.material = mat
	var mesh := ArrayMesh.new()
	var arrays := m.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] += Vector3(0, 6.1, 1.3)
	arrays[Mesh.ARRAY_VERTEX] = verts
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, mat)
	return mesh
