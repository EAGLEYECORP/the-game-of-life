class_name NpcVisuals
extends RefCounted
## Cheap visuals for crowds of NPCs.
##
## A drivable vehicle scene has ~30 mesh nodes, which is fine for the few
## cars you can drive but far too many draw calls for city traffic. Here each
## vehicle type is baked once per paint colour into a single mesh with vertex
## colours (at most 3 surfaces: matte, shiny, glowing), and cached. Pedestrians
## are built the same way: one body mesh plus four limb meshes to animate.
##
## Everything shares three materials, so the renderer can batch state changes.

static var matte: StandardMaterial3D
static var shiny: StandardMaterial3D
static var glow: StandardMaterial3D
static var _cache := {}

## Pedestrian outfits: Casablanca mixes djellabas with everyday western wear.
const ROBE_COLORS := [Color(0.92, 0.9, 0.84), Color(0.55, 0.42, 0.3), Color(0.3, 0.33, 0.45),
	Color(0.7, 0.62, 0.48), Color(0.2, 0.22, 0.2), Color(0.62, 0.2, 0.25)]
const SHIRT_COLORS := [Color(0.9, 0.9, 0.9), Color(0.2, 0.35, 0.6), Color(0.7, 0.2, 0.2),
	Color(0.25, 0.25, 0.28), Color(0.85, 0.7, 0.3), Color(0.35, 0.55, 0.35)]
const TROUSER_COLORS := [Color(0.18, 0.24, 0.38), Color(0.15, 0.15, 0.17), Color(0.5, 0.45, 0.38)]
const SKIN_COLORS := [Color(0.76, 0.57, 0.42), Color(0.62, 0.45, 0.32), Color(0.85, 0.68, 0.54), Color(0.45, 0.32, 0.23)]


## Frees everything cached (template Label3D nodes live outside the tree).
## Called when the traffic system shuts down.
static func clear_cache() -> void:
	for key in _cache:
		var v = _cache[key]
		if v is Dictionary and v.has("labels"):
			for l in v["labels"]:
				l[0].free()
	_cache.clear()
	matte = null
	shiny = null
	glow = null


static func _ensure_materials() -> void:
	if matte:
		return
	matte = _vc_material(0.0, 0.8, false)
	shiny = _vc_material(0.5, 0.25, false)
	glow = _vc_material(0.0, 0.5, true)


static func _vc_material(metal: float, rough: float, emissive: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.metallic = metal
	m.roughness = rough
	if emissive:
		# Glows with its vertex colour (lamps, the taxi sign).
		m.emission_enabled = true
		m.emission_energy_multiplier = 0.6
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


# --- Vehicles -----------------------------------------------------------------

## Everything an AI car needs from a vehicle scene, baked once per colour.
## Returns {mesh, labels: [[Label3D, Transform3D]], shape, shape_xform,
## ride_height, length, width, paint_options, name, scene}.
static func vehicle_template(scene: PackedScene, paint: Color) -> Dictionary:
	_ensure_materials()
	var key := "%s|%s" % [scene.resource_path, paint.to_html()]
	if _cache.has(key):
		return _cache[key]

	var root := scene.instantiate() as Vehicle
	var parts := []   # [mesh, transform, color, group]
	var labels := []
	var ride_height := 0.5
	for node in root.find_children("*", "", true, false):
		if node is Label3D:
			labels.append([node.duplicate(), _xform_to(node, root)])
		if not node is MeshInstance3D or not node.visible:
			continue
		var mi := node as MeshInstance3D
		var t := _xform_to(mi, root)
		var wheel := mi.get_parent() as VehicleWheel3D
		if wheel:
			# Wheels sit lower at rest than their raycast origin.
			t.origin.y -= wheel.wheel_rest_length - 0.04
			ride_height = wheel.wheel_radius + wheel.wheel_rest_length - 0.04 - wheel.position.y
		var color := _albedo(mi)
		var group := "shiny" if _material_metallic(mi) > 0.3 else "matte"
		var n := String(mi.name)
		if n.begins_with("Paint"):
			color = paint
			group = "shiny"
		elif n.begins_with("Glass"):
			group = "shiny"
		elif n.begins_with("Headlight"):
			color = Color(1.0, 0.96, 0.8)
			group = "glow"
		elif n.begins_with("Taillight"):
			color = Color(0.75, 0.05, 0.05)
			group = "glow"
		elif n.begins_with("TaxiSign"):
			color = Color(1, 1, 0.95)
			group = "glow"
		parts.append([mi.mesh, t, color, group])

	var shape_node := root.get_node("CollisionShape3D") as CollisionShape3D
	var box := shape_node.shape as BoxShape3D
	var tpl := {
		"mesh": bake(parts),
		"labels": labels,
		"shape": shape_node.shape,
		"shape_xform": shape_node.transform,
		"ride_height": ride_height,
		"length": box.size.z if box else 4.0,
		"width": box.size.x if box else 1.8,
		"name": root.display_name,
		"scene": scene,
		"two_wheeler": root.two_wheeler,
		"horn": root.get_node("Sounds").horn_style if root.has_node("Sounds") else "car",
	}
	root.free()
	_cache[key] = tpl
	return tpl


## Random paint for a vehicle scene, from its own paint_options.
static func random_paint(scene: PackedScene, rng: RandomNumberGenerator) -> Color:
	var key := "paint|" + scene.resource_path
	if not _cache.has(key):
		var v := scene.instantiate() as Vehicle
		_cache[key] = v.paint_options if v.randomize_paint else PackedColorArray([v.paint_color])
		v.free()
	var opts: PackedColorArray = _cache[key]
	return opts[rng.randi() % opts.size()]


# --- Pedestrians --------------------------------------------------------------

## Builds a pedestrian model under `parent`: a static body mesh and four limb
## meshes pivoting at hips/shoulders. Returns {"legs": [l, r], "arms": [l, r]}.
static func build_pedestrian(parent: Node3D, rng: RandomNumberGenerator) -> Dictionary:
	_ensure_materials()
	var skin: Color = SKIN_COLORS[rng.randi() % SKIN_COLORS.size()]
	var robe := rng.randf() < 0.35
	var top: Color = (ROBE_COLORS if robe else SHIRT_COLORS)[rng.randi() % 6]
	var legs_col: Color = top if robe else TROUSER_COLORS[rng.randi() % TROUSER_COLORS.size()]
	var tall := rng.randf_range(0.92, 1.06)

	var key := "ped|%s|%s|%s|%s" % [robe, top.to_html(), legs_col.to_html(), skin.to_html()]
	if not _cache.has(key):
		var body := []
		if robe:
			# Djellaba: a long robe to the ankles with a pointed hood behind.
			body.append([_cyl(0.24, 0.3, 1.2), Transform3D(Basis(), Vector3(0, 0.75, 0)), top, "matte"])
			body.append([_box(Vector3(0.22, 0.22, 0.12)), Transform3D(Basis(), Vector3(0, 1.45, -0.14)), top.darkened(0.1), "matte"])
		else:
			body.append([_box(Vector3(0.4, 0.55, 0.24)), Transform3D(Basis(), Vector3(0, 1.22, 0)), top, "matte"])
			body.append([_box(Vector3(0.36, 0.16, 0.22)), Transform3D(Basis(), Vector3(0, 0.92, 0)), legs_col, "matte"])
		body.append([_sphere(0.13), Transform3D(Basis(), Vector3(0, 1.66, 0)), skin, "matte"])
		var leg := [[_box(Vector3(0.14, 0.82, 0.14)), Transform3D(Basis(), Vector3(0, -0.41, 0)), legs_col, "matte"],
			[_box(Vector3(0.15, 0.08, 0.24)), Transform3D(Basis(), Vector3(0, -0.8, 0.05)), Color(0.12, 0.1, 0.08), "matte"]]
		var arm := [[_box(Vector3(0.11, 0.6, 0.11)), Transform3D(Basis(), Vector3(0, -0.3, 0)), top, "matte"],
			[_sphere(0.06), Transform3D(Basis(), Vector3(0, -0.62, 0)), skin, "matte"]]
		_cache[key] = {"body": bake(body), "leg": bake(leg), "arm": bake(arm)}
	var meshes: Dictionary = _cache[key]

	parent.scale = Vector3.ONE * tall
	_add_mesh(parent, meshes["body"], Vector3.ZERO)
	var legs := [_add_mesh(parent, meshes["leg"], Vector3(0.1, 0.88, 0)), _add_mesh(parent, meshes["leg"], Vector3(-0.1, 0.88, 0))]
	var arms := [_add_mesh(parent, meshes["arm"], Vector3(0.26, 1.46, 0)), _add_mesh(parent, meshes["arm"], Vector3(-0.26, 1.46, 0))]
	return {"legs": legs, "arms": arms}


# --- Traffic lights -----------------------------------------------------------

## A traffic light post: pole + housing as one mesh, plus three lamp meshes
## (red, amber, green from the top) whose material is swapped by the caller.
static func build_traffic_light(parent: Node3D) -> Array[MeshInstance3D]:
	_ensure_materials()
	if not _cache.has("light_post"):
		var dark := Color(0.12, 0.13, 0.12)
		_cache["light_post"] = bake([
			[_cyl(0.07, 0.07, 3.0), Transform3D(Basis(), Vector3(0, 1.5, 0)), Color(0.3, 0.32, 0.3), "shiny"],
			[_box(Vector3(0.36, 1.0, 0.26)), Transform3D(Basis(), Vector3(0, 3.0, 0)), dark, "matte"],
			[_box(Vector3(0.44, 1.08, 0.04)), Transform3D(Basis(), Vector3(0, 3.0, -0.13)), dark, "matte"],
		])
		_cache["light_lamp"] = _sphere(0.1)
	_add_mesh(parent, _cache["light_post"], Vector3.ZERO)
	var lamps: Array[MeshInstance3D] = []
	for i in 3:
		lamps.append(_add_mesh(parent, _cache["light_lamp"], Vector3(0, 3.32 - i * 0.32, 0.12), false))
	return lamps


## The six lamp materials (index = lamp * 2 + on): red, amber, green.
static func lamp_materials() -> Array[StandardMaterial3D]:
	if not _cache.has("lamp_mats"):
		var mats: Array[StandardMaterial3D] = []
		for c in [Color(1, 0.1, 0.05), Color(1, 0.65, 0.05), Color(0.1, 1, 0.35)]:
			for on in [false, true]:
				var m := StandardMaterial3D.new()
				m.albedo_color = c if on else c.darkened(0.8)
				if on:
					m.emission_enabled = true
					m.emission = c
					m.emission_energy_multiplier = 3.0
				mats.append(m)
		_cache["lamp_mats"] = mats
	return _cache["lamp_mats"]


# --- Baking -------------------------------------------------------------------

## Merges [mesh, transform, color, group] parts into one ArrayMesh with one
## surface per group (matte / shiny / glow), colours stored per vertex.
static func bake(parts: Array) -> ArrayMesh:
	_ensure_materials()
	var groups := {}
	for p in parts:
		var mesh: Mesh = p[0]
		var t: Transform3D = p[1]
		var color: Color = p[2]
		if not groups.has(p[3]):
			groups[p[3]] = [PackedVector3Array(), PackedVector3Array(), PackedColorArray()]
		var g: Array = groups[p[3]]
		for s in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var count := idx.size() if not idx.is_empty() else verts.size()
			for k in count:
				var i := idx[k] if not idx.is_empty() else k
				g[0].append(t * verts[i])
				g[1].append((t.basis * norms[i]).normalized())
				g[2].append(color)
	var out := ArrayMesh.new()
	for name in groups:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = groups[name][0]
		arrays[Mesh.ARRAY_NORMAL] = groups[name][1]
		arrays[Mesh.ARRAY_COLOR] = groups[name][2]
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(out.get_surface_count() - 1,
			glow if name == "glow" else (shiny if name == "shiny" else matte))
	return out


static func _add_mesh(parent: Node3D, mesh: Mesh, pos: Vector3, shadows := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	if not shadows:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


## Transform of `node` relative to `root`, without needing the scene tree.
static func _xform_to(node: Node, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n := node
	while n != root and n != null:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


static func _albedo(mi: MeshInstance3D) -> Color:
	var m := mi.material_override if mi.material_override else mi.mesh.surface_get_material(0)
	return (m as StandardMaterial3D).albedo_color if m is StandardMaterial3D else Color.GRAY


static func _material_metallic(mi: MeshInstance3D) -> float:
	var m := mi.material_override if mi.material_override else mi.mesh.surface_get_material(0)
	return (m as StandardMaterial3D).metallic if m is StandardMaterial3D else 0.0


static func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


static func _cyl(top: float, bottom: float, h: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = h
	m.radial_segments = 10
	return m


static func _sphere(r: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.radial_segments = 10
	m.rings = 6
	return m
