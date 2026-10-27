class_name RoadGraph
extends RefCounted
## The road network used by AI traffic and pedestrians.
##
## Nodes are junctions and dead ends; edges are the road pieces between them,
## each with its polyline, width, class, kind and one-way flag. It comes from
## traffic.json (written by tools/osm/import_osm.gd) or, without OSM data, from
## the placeholder city's grid.
##
## Also answers the questions agents ask all the time, cheaply:
##   - "give me a random road piece 100-250 m from the player" (bucketed index),
##   - "which way can I go at this junction?",
##   - "what's my lane polyline on this edge?",
##   - "is my traffic light green?" (pure function of time, no per-frame work).

enum Kind { WALK_ONLY = 0, STREET = 1, FAST_ROAD = 2 }
enum Light { NONE = -1, GREEN = 0, YELLOW = 1, RED = 2 }

const BUCKET := 100.0             ## Spatial index cell size (m).
## Traffic light cycle (s): group 0 green, yellow, all red, group 1 green...
const GREEN_TIME := 12.0
const YELLOW_TIME := 3.0
const ALL_RED_TIME := 1.5
const CYCLE := (GREEN_TIME + YELLOW_TIME + ALL_RED_TIME) * 2.0

var nodes := PackedVector2Array()
var node_edges: Array[PackedInt32Array] = []
var edge_a := PackedInt32Array()
var edge_b := PackedInt32Array()
var edge_class := PackedInt32Array()      ## 0 paving/footway, 1 minor, 2 major.
var edge_kind := PackedInt32Array()       ## Kind.
var edge_oneway := PackedInt32Array()     ## 1 = only a -> b.
var edge_width := PackedFloat32Array()
var edge_length := PackedFloat32Array()
var edge_points: Array[PackedVector2Array] = []
## node id -> {edge id: light group 0/1}
var signals := {}

var _drive_buckets := {}   # Vector2i -> PackedInt32Array
var _walk_buckets := {}


## Builds the graph from the traffic.json layout. `scale` converts stored
## units to metres (0.1 for the importer's decimetres, 1.0 for metres).
static func from_dict(d: Dictionary, scale: float) -> RoadGraph:
	var g := RoadGraph.new()
	var flat: Array = d.get("nodes", [])
	g.nodes.resize(int(flat.size() / 2.0))
	for i in g.nodes.size():
		g.nodes[i] = Vector2(flat[i * 2], flat[i * 2 + 1]) * scale
	g.node_edges.resize(g.nodes.size())
	for i in g.nodes.size():
		g.node_edges[i] = PackedInt32Array()

	for e in d.get("edges", []):
		# [a, b, class, kind, oneway, width, [x, z, ...]]
		var pts := PackedVector2Array()
		var p: Array = e[6]
		for i in range(0, p.size() - 1, 2):
			pts.append(Vector2(p[i], p[i + 1]) * scale)
		if pts.size() < 2:
			continue
		var id := g.edge_a.size()
		g.edge_a.append(int(e[0]))
		g.edge_b.append(int(e[1]))
		g.edge_class.append(int(e[2]))
		g.edge_kind.append(int(e[3]))
		g.edge_oneway.append(int(e[4]))
		g.edge_width.append(float(e[5]) * scale)
		g.edge_points.append(pts)
		var length := 0.0
		for i in pts.size() - 1:
			length += pts[i].distance_to(pts[i + 1])
		g.edge_length.append(length)
		g.node_edges[int(e[0])].append(id)
		g.node_edges[int(e[1])].append(id)
		g._index_edge(id)

	for n in d.get("signals", []):
		g._add_signal(int(n))
	return g


func edge_count() -> int:
	return edge_a.size()


func is_drivable(e: int) -> bool:
	return edge_kind[e] != Kind.WALK_ONLY


func is_walkable(e: int) -> bool:
	return edge_kind[e] != Kind.FAST_ROAD


## Typical cruising speed (m/s) for AI cars on this edge.
func speed_limit(e: int) -> float:
	if edge_class[e] >= 2:
		return 13.9                       # 50 km/h boulevards.
	return 6.5 if edge_width[e] < 5.0 else 9.5


## True if a car may drive along `e` starting from `node`.
func can_leave(e: int, node: int) -> bool:
	return edge_oneway[e] == 0 or edge_a[e] == node


func other_end(e: int, node: int) -> int:
	return edge_b[e] if edge_a[e] == node else edge_a[e]


## Picks where to go after reaching `node` on edge `from_e`. Avoids U-turns
## unless it's a dead end; favours staying on bigger roads. -1 = nowhere.
func pick_next(from_e: int, node: int, rng: RandomNumberGenerator, walking: bool) -> int:
	var options := PackedInt32Array()
	var weights := PackedFloat32Array()
	var total := 0.0
	for e in node_edges[node]:
		if e == from_e:
			continue
		if walking:
			if not is_walkable(e):
				continue
		elif not is_drivable(e) or not can_leave(e, node):
			continue
		var w := 1.0 if walking else (2.0 if edge_class[e] >= 2 else (0.4 if edge_width[e] < 5.0 else 1.0))
		options.append(e)
		weights.append(w)
		total += w
	if options.is_empty():
		# Dead end: turn around if allowed.
		if walking or can_leave(from_e, node):
			return from_e
		return -1
	var roll := rng.randf() * total
	for i in options.size():
		roll -= weights[i]
		if roll <= 0.0:
			return options[i]
	return options[-1]


## The polyline an agent follows along `e`, starting at `from_node`, shifted
## `offset` metres to the right of the travel direction (negative = left) and
## with `trim` metres cut off both ends so turns cut across the junction.
func lane(e: int, from_node: int, offset: float, trim: float) -> PackedVector2Array:
	var pts := edge_points[e]
	if from_node != edge_a[e]:
		pts = pts.duplicate()
		pts.reverse()
	var out := PackedVector2Array()
	var n := pts.size()
	for i in n:
		var d_in := (pts[i] - pts[maxi(i - 1, 0)]).normalized()
		var d_out := (pts[mini(i + 1, n - 1)] - pts[i]).normalized()
		var dir := (d_in + d_out).normalized()
		if dir == Vector2.ZERO:
			dir = d_out if d_out != Vector2.ZERO else d_in
		out.append(pts[i] + Vector2(-dir.y, dir.x) * offset)
	return _trim(out, minf(trim, edge_length[e] * 0.3))


static func _trim(pts: PackedVector2Array, trim: float) -> PackedVector2Array:
	if trim <= 0.0 or pts.size() < 2:
		return pts
	# Cut the start.
	var d := trim
	while pts.size() > 2 and pts[0].distance_to(pts[1]) <= d:
		d -= pts[0].distance_to(pts[1])
		pts.remove_at(0)
	pts[0] = pts[0].move_toward(pts[1], d)
	# Cut the end.
	d = trim
	while pts.size() > 2 and pts[-1].distance_to(pts[-2]) <= d:
		d -= pts[-1].distance_to(pts[-2])
		pts.remove_at(pts.size() - 1)
	pts[-1] = pts[-1].move_toward(pts[-2], d)
	return pts


## A random spot on a drivable (or walkable) edge between rmin and rmax metres
## from `center`. Returns [edge, from_node, distance_along] or [] if unlucky.
func random_spot(center: Vector2, rmin: float, rmax: float, rng: RandomNumberGenerator, walking: bool) -> Array:
	var buckets := _walk_buckets if walking else _drive_buckets
	for attempt in 10:
		var ang := rng.randf() * TAU
		var r := sqrt(rng.randf_range(rmin * rmin, rmax * rmax))
		var p := center + Vector2(cos(ang), sin(ang)) * r
		var cell := Vector2i((p / BUCKET).floor())
		if not buckets.has(cell):
			continue
		var list: PackedInt32Array = buckets[cell]
		var e := list[rng.randi() % list.size()]
		var along := rng.randf() * edge_length[e]
		var pos := point_along(e, along)
		var dist := pos.distance_to(center)
		if dist < rmin or dist > rmax:
			continue
		var from_node := edge_a[e]
		if not walking and edge_oneway[e] == 0 and rng.randf() < 0.5:
			from_node = edge_b[e]
			along = edge_length[e] - along
		return [e, from_node, along]
	return []


## Point `along` metres from edge_a along the centre line.
func point_along(e: int, along: float) -> Vector2:
	var pts := edge_points[e]
	for i in pts.size() - 1:
		var seg := pts[i].distance_to(pts[i + 1])
		if along <= seg:
			return pts[i].lerp(pts[i + 1], along / maxf(seg, 0.001))
		along -= seg
	return pts[-1]


## Traffic light state for a car on edge `e` arriving at `node`, at time `t`.
func light_at(node: int, e: int, t: float) -> Light:
	if not signals.has(node):
		return Light.NONE
	var group: int = signals[node].get(e, 0)
	# Each junction runs its own offset so the city isn't in lockstep.
	var phase := fposmod(t + float(hash(node) % 1000) * 0.031, CYCLE)
	var half := CYCLE * 0.5
	var mine := phase if group == 0 else fposmod(phase - half, CYCLE)
	if mine < GREEN_TIME:
		return Light.GREEN
	if mine < GREEN_TIME + YELLOW_TIME:
		return Light.YELLOW
	return Light.RED


## Signalled junctions within `radius` of `center`.
func signals_near(center: Vector2, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	for n: int in signals:
		if nodes[n].distance_to(center) <= radius:
			out.append(n)
	return out


# --- Internals ----------------------------------------------------------------

func _index_edge(id: int) -> void:
	var cells := {}
	var pts := edge_points[id]
	for i in pts.size() - 1:
		var steps := maxi(1, ceili(pts[i].distance_to(pts[i + 1]) / (BUCKET * 0.5)))
		for s in steps + 1:
			cells[Vector2i((pts[i].lerp(pts[i + 1], float(s) / steps) / BUCKET).floor())] = true
	for cell: Vector2i in cells:
		if is_drivable(id):
			_add_to(_drive_buckets, cell, id)
		if is_walkable(id):
			_add_to(_walk_buckets, cell, id)


static func _add_to(buckets: Dictionary, cell: Vector2i, id: int) -> void:
	if not buckets.has(cell):
		buckets[cell] = PackedInt32Array()
	var list: PackedInt32Array = buckets[cell]
	list.append(id)
	buckets[cell] = list


## Splits the junction's roads into two light groups by direction: roads
## roughly in line with the first one share its phase, the rest get the other.
func _add_signal(n: int) -> void:
	var groups := {}
	var ref_axis := INF
	for e in node_edges[n]:
		if not is_drivable(e):
			continue
		var pts := edge_points[e]
		var away := (pts[1] - pts[0]) if edge_a[e] == n else (pts[-2] - pts[-1])
		var axis := fposmod(away.angle(), PI)
		if ref_axis == INF:
			ref_axis = axis
		var diff := absf(axis - ref_axis)
		diff = minf(diff, PI - diff)
		groups[e] = 0 if diff < PI * 0.25 else 1
	if groups.size() >= 3:
		signals[n] = groups
