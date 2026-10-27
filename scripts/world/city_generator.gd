@tool
extends Node3D
## Procedurally builds a placeholder Casablanca: a street grid, white-washed
## blocks of flats, palm-lined parks, the Atlantic corniche to the north and a
## tall minaret as a landmark (a nod to the Hassan II Mosque).
##
## This is the fallback world: ChunkStreamer loads it when no OpenStreetMap data
## has been imported yet (see README), so the game always has something to run.
##
## Because the script is a @tool, the city also appears in the editor. Toggle
## "regenerate" in the inspector after changing a setting to rebuild it.
##
## Coordinate notes: roads run along multiples of `cell_size` on X and Z, so the
## origin (0, 0) is always an intersection - a safe place to spawn things.

@export var seed_value := 1907          ## Same seed = same city every run.
@export var blocks_per_side := 8        ## City is blocks_per_side² blocks.
@export var cell_size := 60.0           ## Distance between road centre lines.
@export var road_width := 14.0
@export var sidewalk_width := 3.0
@export var park_chance := 0.12         ## Fraction of blocks that become parks.
@export var regenerate := false:
	set(value):
		regenerate = false
		if is_inside_tree():
			_build()

# Palette: Casablanca ("white house") is mostly white and cream with a few
# ochre and pale blue facades.
const FACADE_COLORS: Array[Color] = [
	Color(0.96, 0.95, 0.92), Color(0.94, 0.92, 0.86), Color(0.98, 0.97, 0.95),
	Color(0.90, 0.86, 0.78), Color(0.87, 0.78, 0.62), Color(0.80, 0.86, 0.90),
]
const ASPHALT := Color(0.18, 0.18, 0.2)
const SIDEWALK := Color(0.62, 0.6, 0.56)
const GRASS := Color(0.32, 0.5, 0.25)
const SAND := Color(0.86, 0.78, 0.6)
const SEA := Color(0.1, 0.35, 0.5)
const LANE_PAINT := Color(0.95, 0.9, 0.7)
const MOSQUE_GREEN := Color(0.1, 0.45, 0.35)

var _rng := RandomNumberGenerator.new()
var _materials := {}   # Color -> StandardMaterial3D, so equal colors share one.
var _root: Node3D      # Container for everything generated, rebuilt on regenerate.


func _ready() -> void:
	_build()


func _build() -> void:
	if _root:
		_root.free()
	_root = Node3D.new()
	_root.name = "Generated"
	add_child(_root)  # Not owned by the scene, so it's never saved into the .tscn.

	_rng.seed = seed_value
	var half := cell_size * blocks_per_side * 0.5

	_build_ground(half)
	_build_roads(half)
	_build_coast(half)
	_build_boundary(half)

	# Pick one block next to the sea for the mosque.
	var mosque_block := Vector2i(int(blocks_per_side * 0.5), 0)
	for ix in blocks_per_side:
		for iz in blocks_per_side:
			var center := Vector3(
				-half + cell_size * (ix + 0.5), 0.0, -half + cell_size * (iz + 0.5))
			if Vector2i(ix, iz) == mosque_block:
				_build_mosque(center)
			elif _rng.randf() < park_chance:
				_build_park(center)
			else:
				_build_city_block(center, half)


## Parking spots along every road, on the right-hand side, skipping
## intersections. Used by VehicleSpawner: [{pos: Vector3, yaw: float}].
func get_parking_spots() -> Array:
	var spots := []
	var half := cell_size * blocks_per_side * 0.5
	var lane := road_width * 0.3
	for i in blocks_per_side + 1:
		var offset := -half + cell_size * i
		var d := -half + 15.0
		while d < half:
			var local := fposmod(d + half, cell_size)
			if local > road_width and local < cell_size - road_width:
				# Road along X heading +X: right-hand side is +Z.
				spots.append({"pos": Vector3(d, 0.7, offset + lane), "yaw": PI * 0.5})
				# Road along Z heading -Z: right-hand side is +X.
				spots.append({"pos": Vector3(offset + lane, 0.7, -d), "yaw": PI})
			d += 22.0
	return spots


# --- Terrain ---------------------------------------------------------------

func _build_ground(half: float) -> void:
	# One big collider for the whole city; roads/sidewalks are visual only so
	# cars never catch on seams between road pieces.
	var size := Vector3(half * 2.0 + 40.0, 1.0, half * 2.0 + 40.0)
	_add_box(Vector3(0, -0.5, 0), size, SIDEWALK, true)


func _build_roads(half: float) -> void:
	var length := half * 2.0 + road_width
	var lines := blocks_per_side + 1
	for i in lines:
		var offset := -half + cell_size * i
		# Roads along X and along Z. Slightly above ground to avoid z-fighting.
		_add_box(Vector3(0, 0.01, offset), Vector3(length, 0.02, road_width), ASPHALT, false)
		_add_box(Vector3(offset, 0.011, 0), Vector3(road_width, 0.02, length), ASPHALT, false)
	_build_lane_markings(half, lines)


## Dashed centre lines, drawn with one MultiMesh so thousands of dashes cost a
## single draw call.
func _build_lane_markings(half: float, lines: int) -> void:
	var dash := BoxMesh.new()
	dash.size = Vector3(0.25, 0.02, 3.0)
	dash.material = _material(LANE_PAINT)

	var transforms: Array[Transform3D] = []
	var step := 7.0
	for i in lines:
		var offset := -half + cell_size * i
		var d := -half
		while d < half:
			# Skip dashes inside intersections.
			var local := fposmod(d + half, cell_size)
			if local > road_width * 0.5 and local < cell_size - road_width * 0.5:
				transforms.append(Transform3D(Basis(), Vector3(offset, 0.03, d)))
				transforms.append(Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(d, 0.03, offset)))
			d += step

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = dash
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "LaneMarkings"
	mmi.multimesh = mm
	_root.add_child(mmi)


## Beach and the Atlantic along the north edge (negative Z), with palms on the
## corniche promenade.
func _build_coast(half: float) -> void:
	var width := half * 2.0 + 40.0
	_add_box(Vector3(0, 0.005, -half - 15.0), Vector3(width, 0.02, 10.0), SAND, false)
	var sea := _add_box(Vector3(0, -0.6, -half - 420.0), Vector3(2000.0, 0.1, 800.0), SEA, false)
	var sea_mat: StandardMaterial3D = _material(SEA).duplicate()
	sea_mat.roughness = 0.05
	sea_mat.metallic = 0.3
	sea.material_override = sea_mat

	var x := -half
	while x <= half:
		_add_palm(Vector3(x, 0, -half - road_width * 0.5 - 2.0))
		x += 18.0


## Invisible walls so nobody drives off the edge of the world.
func _build_boundary(half: float) -> void:
	var edge := half + 20.0
	var h := 6.0
	for side in [Vector3(0, h * 0.5, -edge), Vector3(0, h * 0.5, edge)]:
		_add_collider(side, Vector3(edge * 2.0, h, 1.0))
	for side in [Vector3(-edge, h * 0.5, 0), Vector3(edge, h * 0.5, 0)]:
		_add_collider(side, Vector3(1.0, h, edge * 2.0))
	# A low sea wall the player can see.
	_add_box(Vector3(0, 0.4, -edge + 0.5), Vector3(edge * 2.0, 0.8, 0.6), SIDEWALK, true)


# --- Blocks ----------------------------------------------------------------

## A block of 2x2 to 3x3 buildings. Blocks near the centre get taller,
## like a downtown.
func _build_city_block(center: Vector3, half: float) -> void:
	var lot := cell_size - road_width - sidewalk_width * 2.0
	var splits := _rng.randi_range(2, 3)
	var plot := lot / splits
	var downtown := 1.0 - clampf(Vector2(center.x, center.z).length() / half, 0.0, 1.0)

	for gx in splits:
		for gz in splits:
			var pos := center + Vector3(
				-lot * 0.5 + plot * (gx + 0.5), 0.0, -lot * 0.5 + plot * (gz + 0.5))
			var w := plot * _rng.randf_range(0.75, 0.95)
			var d := plot * _rng.randf_range(0.75, 0.95)
			var h := _rng.randf_range(6.0, 18.0) + downtown * downtown * _rng.randf_range(0.0, 55.0)
			_add_building(pos, Vector3(w, h, d))


func _add_building(pos: Vector3, size: Vector3) -> void:
	var color: Color = FACADE_COLORS[_rng.randi() % FACADE_COLORS.size()]
	_add_box(pos + Vector3(0, size.y * 0.5, 0), size, color, true)
	# Darker parapet on the roof for a bit of silhouette.
	_add_box(pos + Vector3(0, size.y + 0.4, 0), Vector3(size.x + 0.4, 0.8, size.z + 0.4),
			color.darkened(0.15), false)


func _build_park(center: Vector3) -> void:
	var lot := cell_size - road_width
	_add_box(center + Vector3(0, 0.02, 0), Vector3(lot, 0.04, lot), GRASS, false)
	for _i in 10:
		var offset := Vector3(_rng.randf_range(-0.4, 0.4) * lot, 0, _rng.randf_range(-0.4, 0.4) * lot)
		_add_palm(center + offset)


## Plaza with a tall square minaret, inspired by the Hassan II Mosque.
func _build_mosque(center: Vector3) -> void:
	var lot := cell_size - road_width
	_add_box(center + Vector3(0, 0.05, 0), Vector3(lot, 0.1, lot), Color(0.92, 0.88, 0.8), false)
	# Prayer hall.
	_add_box(center + Vector3(0, 6.0, 6.0), Vector3(lot * 0.8, 12.0, lot * 0.45),
			Color(0.95, 0.93, 0.88), true)
	_add_box(center + Vector3(0, 12.4, 6.0), Vector3(lot * 0.8, 0.8, lot * 0.45), MOSQUE_GREEN, false)
	# Minaret: shaft, green band, lantern.
	var m := center + Vector3(0, 0, -12.0)
	_add_box(m + Vector3(0, 45.0, 0), Vector3(9.0, 90.0, 9.0), Color(0.93, 0.9, 0.84), true)
	_add_box(m + Vector3(0, 80.0, 0), Vector3(9.4, 6.0, 9.4), MOSQUE_GREEN, false)
	_add_box(m + Vector3(0, 95.0, 0), Vector3(5.0, 10.0, 5.0), Color(0.93, 0.9, 0.84), false)
	_add_box(m + Vector3(0, 101.0, 0), Vector3(5.4, 2.0, 5.4), MOSQUE_GREEN, false)


func _add_palm(pos: Vector3) -> void:
	var height := _rng.randf_range(6.0, 9.0)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.18
	trunk.bottom_radius = 0.3
	trunk.height = height
	trunk.material = _material(Color(0.45, 0.33, 0.2))

	var body := StaticBody3D.new()
	body.position = pos
	_root.add_child(body)

	var trunk_mesh := MeshInstance3D.new()
	trunk_mesh.mesh = trunk
	trunk_mesh.position.y = height * 0.5
	body.add_child(trunk_mesh)

	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.3
	cyl.height = height
	shape.shape = cyl
	shape.position.y = height * 0.5
	body.add_child(shape)

	# Fronds: a few flattened, tilted boxes fanned around the top.
	var frond := BoxMesh.new()
	frond.size = Vector3(0.6, 0.08, 3.2)
	frond.material = _material(Color(0.2, 0.45, 0.18))
	for i in 6:
		var leaf := MeshInstance3D.new()
		leaf.mesh = frond
		var yaw := TAU * i / 6.0 + _rng.randf() * 0.3
		leaf.basis = Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, 0.35)
		leaf.position = Vector3(0, height, 0) + leaf.basis.z * 1.4
		body.add_child(leaf)


# --- Helpers ---------------------------------------------------------------

## Adds a box mesh. With `solid`, it also gets a matching static collider.
## Returns the MeshInstance3D so callers can tweak it.
func _add_box(pos: Vector3, size: Vector3, color: Color, solid: bool) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = _material(color)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh

	if solid:
		var body := _add_collider(pos, size)
		body.add_child(mi)
	else:
		mi.position = pos
		_root.add_child(mi)
	return mi


func _add_collider(pos: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_root.add_child(body)
	return body


func _material(color: Color) -> StandardMaterial3D:
	if not _materials.has(color):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.85
		_materials[color] = mat
	return _materials[color]
