class_name ChunkBuilder
extends RefCounted
## Turns one chunk's JSON (written by tools/osm/import_osm.gd) into mesh arrays
## and collision triangles.
##
## Pure data in, pure data out, no nodes or servers touched, so it is safe to
## run on a WorkerThreadPool thread. ChunkStreamer turns the result into an
## ArrayMesh and a ConcavePolygonShape3D on the main thread.
##
## Everything goes into a single vertex-coloured surface, so a whole chunk
## (buildings, roads, ground, parks) is one draw call.

const DM := 0.1   # Chunk files store decimetres.

# Height of each layer above y = 0. Stacked a few cm apart so they never
# z-fight, low enough that wheels and feet don't notice the steps.
const Y_GROUND := 0.0
const Y_GREEN := 0.015
const Y_ROAD := [0.03, 0.05, 0.06]   # Indexed by road class: paving, minor, major.

const ROAD_COLORS := [Color(0.63, 0.59, 0.53), Color(0.24, 0.24, 0.26), Color(0.18, 0.18, 0.2)]
const GREEN_COLORS := {
	"park": Color(0.33, 0.5, 0.26), "pitch": Color(0.3, 0.55, 0.3),
	"beach": Color(0.87, 0.79, 0.62), "plaza": Color(0.86, 0.83, 0.76),
}
const GROUND_COLOR := Color(0.7, 0.68, 0.63)


## Result of a build: mesh arrays + collision faces.
class Result:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var collision := PackedVector3Array()
	## Parking spots on this chunk's streets: [{pos: Vector3, yaw: float}].
	var spots: Array[Dictionary] = []

	## Adds a triangle facing `n`. Callers may pass the corners in either order:
	## Godot treats clockwise-wound triangles (seen from the front) as front
	## faces, so the order is fixed up here to match the normal.
	func tri(a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color, solid: bool) -> void:
		if (b - a).cross(c - a).dot(n) > 0.0:
			var t := b
			b = c
			c = t
		verts.append_array([a, b, c])
		normals.append_array([n, n, n])
		colors.append_array([col, col, col])
		if solid:
			collision.append_array([a, b, c])

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color, solid: bool) -> void:
		tri(a, b, c, n, col, solid)
		tri(a, c, d, n, col, solid)

	func mesh_arrays() -> Array:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		return arrays


static func build(data: Dictionary) -> Result:
	var out := Result.new()
	_build_ground(data.get("l", []), out)
	for g in data.get("g", []):
		_build_flat_polygon(_decode(g["p"]), Y_GREEN, GREEN_COLORS.get(g["k"], GROUND_COLOR), false, out)
	for r in data.get("r", []):
		_build_road(_decode(r["p"]), r["w"] * DM, int(r["c"]), out)
	for b in data.get("b", []):
		_build_building(_decode(b["p"]), b["h"] * DM, Color.html(b["c"]), out)
	# Parking spots: flat [x_dm, z_dm, yaw_milliradians, ...].
	var s: Array = data.get("s", [])
	for i in range(0, s.size() - 2, 3):
		out.spots.append({"pos": Vector3(s[i] * DM, 0.7, s[i + 1] * DM), "yaw": s[i + 2] * 0.001})
	return out


static func _decode(flat: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.resize(int(flat.size() / 2.0))
	for i in pts.size():
		pts[i] = Vector2(flat[i * 2], flat[i * 2 + 1]) * DM
	return pts


## Land rectangles from the coastline mask: the walkable/drivable ground.
static func _build_ground(flat: Array, out: Result) -> void:
	for i in range(0, flat.size(), 4):
		var x0: float = flat[i] * DM
		var z0: float = flat[i + 1] * DM
		var x1: float = flat[i + 2] * DM
		var z1: float = flat[i + 3] * DM
		out.quad(Vector3(x0, Y_GROUND, z0), Vector3(x1, Y_GROUND, z0),
			Vector3(x1, Y_GROUND, z1), Vector3(x0, Y_GROUND, z1), Vector3.UP, GROUND_COLOR, true)


## Flat polygon (park, beach, plaza, roof) at height y.
static func _build_flat_polygon(ring: PackedVector2Array, y: float, col: Color, solid: bool, out: Result) -> void:
	var idx := Geometry2D.triangulate_polygon(ring)
	if idx.is_empty():
		# Self-intersecting outline: fall back to its convex hull.
		ring = Geometry2D.convex_hull(ring)
		ring.resize(ring.size() - 1)
		idx = Geometry2D.triangulate_polygon(ring)
	for t in range(0, idx.size(), 3):
		var a := ring[idx[t]]
		var b := ring[idx[t + 1]]
		var c := ring[idx[t + 2]]
		out.tri(Vector3(a.x, y, a.y), Vector3(b.x, y, b.y), Vector3(c.x, y, c.y), Vector3.UP, col, solid)


## Ribbon along a polyline with mitred joints and half-width end caps, so
## pieces overlap cleanly at junctions and chunk borders.
static func _build_road(pts: PackedVector2Array, width: float, cls: int, out: Result) -> void:
	var n := pts.size()
	if n < 2:
		return
	var hw := width * 0.5
	var y: float = Y_ROAD[cls]
	var col: Color = ROAD_COLORS[cls]

	# Extend both ends by half the width (square caps).
	pts = pts.duplicate()
	pts[0] -= (pts[1] - pts[0]).normalized() * hw
	pts[n - 1] += (pts[n - 1] - pts[n - 2]).normalized() * hw

	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for i in n:
		var d_in := (pts[i] - pts[maxi(i - 1, 0)]).normalized()
		var d_out := (pts[mini(i + 1, n - 1)] - pts[i]).normalized()
		if i == 0:
			d_in = d_out
		elif i == n - 1:
			d_out = d_in
		var tangent := (d_in + d_out).normalized()
		if tangent == Vector2.ZERO:
			tangent = d_out
		var normal := Vector2(-tangent.y, tangent.x)
		# Miter length grows on sharp turns; clamp so hairpins don't spike.
		var miter := hw / maxf(normal.dot(Vector2(-d_in.y, d_in.x)), 0.5)
		left.append(pts[i] + normal * miter)
		right.append(pts[i] - normal * miter)

	for i in n - 1:
		out.quad(Vector3(left[i].x, y, left[i].y), Vector3(left[i + 1].x, y, left[i + 1].y),
			Vector3(right[i + 1].x, y, right[i + 1].y), Vector3(right[i].x, y, right[i].y),
			Vector3.UP, col, true)


## Extrudes a footprint into walls + flat roof. Rings are counter-clockwise
## (positive area in x/z), so the outward normal of edge a->b is (dz, -dx).
static func _build_building(ring: PackedVector2Array, h: float, col: Color, out: Result) -> void:
	var n := ring.size()
	var wall_col := col
	for i in n:
		var a := ring[i]
		var b := ring[(i + 1) % n]
		var d := b - a
		if d.length_squared() < 0.0001:
			continue
		var nrm := Vector3(d.y, 0.0, -d.x).normalized()
		out.quad(Vector3(a.x, 0.0, a.y), Vector3(a.x, h, a.y), Vector3(b.x, h, b.y),
			Vector3(b.x, 0.0, b.y), nrm, wall_col, true)
	_build_flat_polygon(ring, h, col.darkened(0.12), true, out)
