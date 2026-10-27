extends SceneTree
## Converts raw Overpass downloads into streamable map chunks for the game.
##
##   godot --headless --script res://tools/osm/import_osm.gd
##
## Optional arguments after `--`:
##   --raw=<dir>   Folder with Overpass JSON files (default data/osm/raw).
##   --out=<dir>   Output folder (default maps/casablanca_osm).
##
## What it does:
##   1. Reads every *.json in the raw folder (Overpass `out geom` format) and
##      drops duplicates (areas overlap).
##   2. Projects lat/lon to local metres around OsmConfig.ORIGIN.
##   3. Works out building heights (height tag > levels > name > type > area).
##   4. Rasterises the coastline into a land/sea mask, so the sea is real sea.
##   5. Cuts everything into CHUNK_SIZE tiles and writes one JSON per tile,
##      plus manifest.json (spawn, car spawns, districts) and skyline.json.
##
## Chunk files store lengths as integer decimetres to stay small and exact.

const DM := 10.0   # Decimetres per metre in the output files.

var _raw_dir := OsmConfig.RAW_DIR
var _out_dir := OsmConfig.OUT_DIR

# Parsed features, in local metres.
var _buildings: Array[Dictionary] = []   # {ring: PackedVector2Array, h, color, name}
var _greens: Array[Dictionary] = []      # {ring, kind}
var _roads: Array[Dictionary] = []       # {pts: PackedVector2Array, w, kind, cls}
var _coast: Array[PackedVector2Array] = []
var _signal_points := PackedVector2Array()   # OSM traffic_signals nodes.
var _gnode_ids := {}                         # Road graph: point key -> node id
var _gnode_pos := PackedVector2Array()

# Area rectangles in local metres, same order as OsmConfig.AREAS.
var _area_rects: Array[Rect2] = []
var _bounds: Rect2

# Land mask: 1 = land, 2 = sea, row-major, _mask_w x _mask_h cells.
var _mask := PackedByteArray()
var _mask_w := 0
var _mask_h := 0

var _chunks := {}   # "cx_cz" -> {b: [], r: [], g: [], l: []}


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--raw="):
			_raw_dir = a.trim_prefix("--raw=")
		elif a.begins_with("--out="):
			_out_dir = a.trim_prefix("--out=")

	var t0 := Time.get_ticks_msec()
	_setup_bounds()
	var elements := _load_raw()
	if elements.is_empty():
		printerr("No OSM data found in %s. Run tools/osm/fetch_osm.gd first (see README)." % _raw_dir)
		quit(1)
		return
	_parse(elements)
	print("Parsed %d buildings, %d roads, %d green areas, %d coastline ways."
		% [_buildings.size(), _roads.size(), _greens.size(), _coast.size()])

	_add_landmark_fallbacks()
	_build_land_mask()
	var skyline := _distribute()
	var manifest := _make_manifest()
	var traffic := _build_road_graph()
	_write(manifest, skyline)
	_save_json(_out_dir.path_join("traffic.json"), traffic)
	print("Import finished in %.1f s: %d chunks, %d skyline buildings -> %s"
		% [(Time.get_ticks_msec() - t0) / 1000.0, _chunks.size(), skyline.size(), _out_dir])
	quit(0)


# --- Loading ----------------------------------------------------------------

func _setup_bounds() -> void:
	for area in OsmConfig.AREAS:
		_area_rects.append(_bbox_to_rect(area["bbox"]))
	_bounds = _bbox_to_rect(OsmConfig.union_bbox())


## [s, w, n, e] -> local Rect2 (x = east, y = local z = south).
func _bbox_to_rect(b: Array) -> Rect2:
	var nw := OsmConfig.project(b[2], b[1])
	var se := OsmConfig.project(b[0], b[3])
	return Rect2(nw, se - nw)


func _load_raw() -> Array:
	var seen := {}
	var out := []
	var dir := DirAccess.open(_raw_dir)
	if dir == null:
		return out
	for file in dir.get_files():
		if not file.ends_with(".json"):
			continue
		var text := FileAccess.get_file_as_string(_raw_dir.path_join(file))
		var data = JSON.parse_string(text)
		if typeof(data) != TYPE_DICTIONARY or not data.has("elements"):
			printerr("Skipping %s: not an Overpass JSON file." % file)
			continue
		for el in data["elements"]:
			var key := "%s/%s" % [el.get("type", ""), el.get("id", 0)]
			if not seen.has(key):
				seen[key] = true
				out.append(el)
		print("Loaded %s" % file)
	return out


# --- Parsing ----------------------------------------------------------------

func _parse(elements: Array) -> void:
	for el in elements:
		var tags: Dictionary = el.get("tags", {})
		var type: String = el.get("type", "")
		if type == "way" and el.has("geometry"):
			var pts := _project_geometry(el["geometry"])
			if tags.get("natural", "") == "coastline":
				_coast.append(pts)
			elif tags.has("highway"):
				_parse_road(pts, tags)
			elif tags.has("building") or tags.has("building:part"):
				_add_building(pts, tags, int(el["id"]))
			else:
				_add_green(pts, tags)
		elif type == "node" and tags.get("highway", "") == "traffic_signals":
			_signal_points.append(OsmConfig.project(el["lat"], el["lon"]))
		elif type == "relation" and tags.has("building"):
			# Multipolygon building: join the outer member ways into rings.
			# Inner rings (courtyards) are ignored; the roof covers them.
			var parts: Array[PackedVector2Array] = []
			for m in el.get("members", []):
				if m.get("role", "") == "outer" and m.has("geometry"):
					parts.append(_project_geometry(m["geometry"]))
			for ring in _join_rings(parts):
				_add_building(ring, tags, int(el["id"]))


func _project_geometry(geom: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for g in geom:
		if g == null:   # Overpass leaves nulls for nodes outside the bbox.
			continue
		var p := OsmConfig.project(g["lat"], g["lon"])
		if pts.is_empty() or pts[-1].distance_to(p) > 0.05:
			pts.append(p)
	return pts


## Turns a closed way into a clean ring: no repeated end point, counter-
## clockwise (positive signed area), at least 3 points.
func _to_ring(pts: PackedVector2Array) -> PackedVector2Array:
	if pts.size() >= 2 and pts[0].distance_to(pts[-1]) < 0.05:
		pts = pts.slice(0, pts.size() - 1)
	if pts.size() < 3:
		return PackedVector2Array()
	var area := _signed_area(pts)
	if absf(area) < 4.0:
		return PackedVector2Array()
	if area < 0.0:
		pts.reverse()
	return pts


func _signed_area(pts: PackedVector2Array) -> float:
	var a := 0.0
	for i in pts.size():
		var p := pts[i]
		var q := pts[(i + 1) % pts.size()]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


## Chains open ways end-to-end into closed rings (multipolygon outers are
## often split into several ways).
func _join_rings(parts: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var rings: Array[PackedVector2Array] = []
	var open := parts.duplicate()
	while not open.is_empty():
		var cur: PackedVector2Array = open.pop_back()
		var grew := true
		while grew and cur[0].distance_to(cur[-1]) > 0.1:
			grew = false
			for i in open.size():
				var p: PackedVector2Array = open[i]
				if cur[-1].distance_to(p[0]) < 0.1:
					cur.append_array(p.slice(1))
				elif cur[-1].distance_to(p[-1]) < 0.1:
					p.reverse()
					cur.append_array(p.slice(1))
				else:
					continue
				open.remove_at(i)
				grew = true
				break
		if cur[0].distance_to(cur[-1]) <= 0.1:
			rings.append(cur)
	return rings


func _add_building(pts: PackedVector2Array, tags: Dictionary, id: int) -> void:
	var ring := _to_ring(pts)
	if ring.is_empty():
		return
	var center := _centroid(ring)
	var area_idx := _area_at(center)
	var h := _building_height(tags, id, area_idx)
	# building:part outlines overlap their parent building. Keep only the tall
	# ones (minarets, towers) that actually change the skyline.
	if tags.has("building:part") and not tags.has("building") and h < 30.0:
		return
	_buildings.append({
		"ring": ring, "h": h, "name": tags.get("name", ""),
		"color": _pick_color(id, area_idx),
	})


func _add_green(pts: PackedVector2Array, tags: Dictionary) -> void:
	var kind := ""
	if tags.get("natural", "") == "beach":
		kind = "beach"
	elif tags.has("leisure") or tags.has("landuse"):
		kind = "pitch" if tags.get("leisure", "") == "pitch" else "park"
	if kind == "":
		return
	var ring := _to_ring(pts)
	if not ring.is_empty():
		_greens.append({"ring": ring, "kind": kind})


func _parse_road(pts: PackedVector2Array, tags: Dictionary) -> void:
	var kind: String = tags["highway"]
	if not OsmConfig.ROAD_WIDTHS.has(kind) or pts.size() < 2:
		return
	if tags.get("tunnel", "no") != "no" or tags.get("access", "") == "private" and kind == "service":
		return
	# Closed pedestrian ways tagged area=yes are squares/plazas, not lines.
	if tags.get("area", "no") == "yes":
		var ring := _to_ring(pts)
		if not ring.is_empty():
			_greens.append({"ring": ring, "kind": "plaza"})
		return

	var w: float = OsmConfig.ROAD_WIDTHS[kind]
	var tagged_w := _parse_metres(tags.get("width", ""))
	if tagged_w > 1.0 and tagged_w < 40.0:
		w = tagged_w
	elif tags.has("lanes") and kind in OsmConfig.CAR_ROADS:
		w = maxf(w, clampf(_parse_metres(tags["lanes"]) * 3.3, 3.0, 30.0))

	# Road class drives colour and height: 2 = major, 1 = minor, 0 = paving.
	var cls := 0
	if kind in OsmConfig.CAR_ROADS:
		cls = 2 if kind.get_slice("_", 0) in ["motorway", "trunk", "primary", "secondary"] else 1
	# One-way streets: "yes"/"1"/"true", roundabouts and motorways, or "-1"
	# (one-way against the drawing direction, so flip the points).
	var oneway := 0
	var ow := String(tags.get("oneway", ""))
	if ow == "-1":
		oneway = 1
		pts = pts.duplicate()
		pts.reverse()
	elif ow in ["yes", "1", "true"] or tags.get("junction", "") in ["roundabout", "circular"] \
			or (kind.begins_with("motorway") and ow != "no"):
		oneway = 1
	_roads.append({"pts": pts, "w": w, "kind": kind, "cls": cls, "oneway": oneway})


func _building_height(tags: Dictionary, id: int, area_idx: int) -> float:
	var h := _parse_metres(tags.get("height", ""))
	if h > 0.0:
		return h
	var levels := _parse_metres(tags.get("building:levels", ""))
	if levels > 0.0:
		return levels * OsmConfig.LEVEL_HEIGHT + _parse_metres(tags.get("roof:levels", "")) * 2.0 + 1.0
	var name := String(tags.get("name", "")).to_lower()
	for key: String in OsmConfig.NAME_HEIGHT_OVERRIDES:
		if name.contains(key):
			return OsmConfig.NAME_HEIGHT_OVERRIDES[key]
	var type := String(tags.get("building", tags.get("building:part", "yes")))
	if OsmConfig.TYPE_HEIGHTS.has(type) and not type in ["residential", "apartments", "commercial"]:
		return OsmConfig.TYPE_HEIGHTS[type]
	# Unknown: pick a stable value in the district's typical range.
	var range_h: Array = OsmConfig.AREAS[area_idx]["heights"] if area_idx >= 0 else OsmConfig.DEFAULT_HEIGHTS
	return lerpf(range_h[0], range_h[1], _hash01(id))


## "12", "12 m", "12.5m", "40'" -> metres. Returns 0 if not a number.
func _parse_metres(value) -> float:
	var s := str(value).strip_edges().to_lower()
	if s.is_empty():
		return 0.0
	var feet := s.ends_with("'") or s.ends_with("ft")
	s = s.replace("m", "").replace("ft", "").replace("'", "").replace(",", ".").strip_edges()
	if not s.is_valid_float():
		return 0.0
	return s.to_float() * (0.3048 if feet else 1.0)


func _pick_color(id: int, area_idx: int) -> Color:
	var palette: Array = OsmConfig.AREAS[area_idx]["palette"] if area_idx >= 0 else OsmConfig.DEFAULT_PALETTE
	var c: Color = palette[int(_hash01(id * 7 + 3) * palette.size()) % palette.size()]
	# Small per-building shade variation so blocks don't look like one slab.
	return c.darkened(_hash01(id * 13 + 1) * 0.08)


func _hash01(n: int) -> float:
	return float(hash(n) % 10000) / 10000.0


func _area_at(p: Vector2) -> int:
	for i in _area_rects.size():
		if _area_rects[i].has_point(p):
			return i
	return -1


func _centroid(ring: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in ring:
		c += p
	return c / ring.size()


## Adds stand-in landmarks (e.g. the Hassan II minaret) when the OSM extract
## doesn't already have something that tall at that spot.
func _add_landmark_fallbacks() -> void:
	for lm in OsmConfig.LANDMARK_FALLBACKS:
		var c := OsmConfig.project(lm["lat"], lm["lon"])
		if not _bounds.has_point(c):
			continue
		var found := false
		for b in _buildings:
			if b["h"] >= lm["height"] * 0.6 and _centroid(b["ring"]).distance_to(c) < 300.0:
				found = true
				break
		if found:
			continue
		var s: float = lm["size"] * 0.5
		var ring := PackedVector2Array([c + Vector2(-s, -s), c + Vector2(-s, s), c + Vector2(s, s), c + Vector2(s, -s)])
		_buildings.append({"ring": _to_ring(ring), "h": lm["height"], "name": lm["name"], "color": lm["color"]})
		print("Added fallback landmark: %s" % lm["name"])


# --- Land / sea mask ----------------------------------------------------------

## Rasterises the coastline into a grid. OSM coastlines have land on their left,
## so cells next to the line get a side from the nearest segment, then a flood
## fill spreads land/sea into the rest of the grid. No coastline = all land.
func _build_land_mask() -> void:
	var cell := OsmConfig.LAND_CELL
	_mask_w = ceili(_bounds.size.x / cell)
	_mask_h = ceili(_bounds.size.y / cell)
	_mask = PackedByteArray()
	_mask.resize(_mask_w * _mask_h)
	if _coast.is_empty():
		_mask.fill(1)
		return

	var best := PackedFloat32Array()
	best.resize(_mask.size())
	best.fill(INF)

	for line in _coast:
		for i in line.size() - 1:
			var a := line[i]
			var b := line[i + 1]
			var steps := maxi(1, ceili(a.distance_to(b) / (cell * 0.5)))
			for s in steps + 1:
				var p := a.lerp(b, float(s) / steps)
				var gx := floori((p.x - _bounds.position.x) / cell)
				var gz := floori((p.y - _bounds.position.y) / cell)
				for dz in range(-2, 3):
					for dx in range(-2, 3):
						var x := gx + dx
						var z := gz + dz
						if x < 0 or z < 0 or x >= _mask_w or z >= _mask_h:
							continue
						var idx := z * _mask_w + x
						var c := _bounds.position + Vector2(x + 0.5, z + 0.5) * cell
						var q := Geometry2D.get_closest_point_to_segment(c, a, b)
						var d := c.distance_squared_to(q)
						if d < best[idx]:
							best[idx] = d
							# Left of a->b in map view (north up) is land. Our
							# local z points south, which flips the sign.
							var cross := (b.y - a.y) * (c.x - a.x) - (b.x - a.x) * (c.y - a.y)
							_mask[idx] = 1 if cross > 0.0 else 2

	# Breadth-first flood fill from every labelled cell.
	var queue := PackedInt32Array()
	for i in _mask.size():
		if _mask[i] != 0:
			queue.append(i)
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		var x := i % _mask_w
		var z := i / _mask_w
		for n in [[x - 1, z], [x + 1, z], [x, z - 1], [x, z + 1]]:
			if n[0] < 0 or n[1] < 0 or n[0] >= _mask_w or n[1] >= _mask_h:
				continue
			var j: int = n[1] * _mask_w + n[0]
			if _mask[j] == 0:
				_mask[j] = _mask[i]
				queue.append(j)

	var land := 0
	for v in _mask:
		land += 1 if v == 1 else 0
	print("Land mask %dx%d: %.0f%% land." % [_mask_w, _mask_h, 100.0 * land / _mask.size()])


func _is_land(p: Vector2) -> bool:
	var x := floori((p.x - _bounds.position.x) / OsmConfig.LAND_CELL)
	var z := floori((p.y - _bounds.position.y) / OsmConfig.LAND_CELL)
	if x < 0 or z < 0 or x >= _mask_w or z >= _mask_h:
		return false
	return _mask[z * _mask_w + x] == 1


# --- Chunking -----------------------------------------------------------------

func _chunk_key(p: Vector2) -> String:
	return "%d_%d" % [floori(p.x / OsmConfig.CHUNK_SIZE), floori(p.y / OsmConfig.CHUNK_SIZE)]


func _chunk(key: String) -> Dictionary:
	if not _chunks.has(key):
		_chunks[key] = {"b": [], "r": [], "g": [], "l": []}
	return _chunks[key]


## Sorts every feature into chunks. Returns the skyline buildings, which are
## kept out of the chunks and always loaded.
func _distribute() -> Array:
	var skyline := []
	for b in _buildings:
		var entry := {"p": _encode(b["ring"]), "h": roundi(b["h"] * DM), "c": b["color"].to_html(false)}
		if b["h"] >= OsmConfig.SKYLINE_MIN_HEIGHT:
			skyline.append(entry)
		else:
			_chunk(_chunk_key(_centroid(b["ring"])))["b"].append(entry)

	# Roads: cut into <= 25 m pieces, group consecutive pieces per chunk.
	for r in _roads:
		var pts := _subdivide(r["pts"], 25.0)
		var run := PackedVector2Array([pts[0]])
		var run_key := _chunk_key((pts[0] + pts[1]) * 0.5)
		for i in range(1, pts.size()):
			var key := _chunk_key((pts[i - 1] + pts[i]) * 0.5)
			if key != run_key:
				_add_road_run(run_key, run, r)
				run = PackedVector2Array([pts[i - 1]])
				run_key = key
			run.append(pts[i])
		_add_road_run(run_key, run, r)

	# Green areas and plazas: clipped to each chunk they overlap.
	for g in _greens:
		var ring: PackedVector2Array = g["ring"]
		var box := _ring_bounds(ring)
		var c0 := (box.position / OsmConfig.CHUNK_SIZE).floor()
		var c1 := (box.end / OsmConfig.CHUNK_SIZE).floor()
		for cz in range(int(c0.y), int(c1.y) + 1):
			for cx in range(int(c0.x), int(c1.x) + 1):
				var s := OsmConfig.CHUNK_SIZE
				var rect := PackedVector2Array([Vector2(cx, cz) * s, Vector2(cx + 1, cz) * s,
					Vector2(cx + 1, cz + 1) * s, Vector2(cx, cz + 1) * s])
				for piece in Geometry2D.intersect_polygons(ring, rect):
					var clean := _to_ring(piece)
					if not clean.is_empty():
						_chunk("%d_%d" % [cx, cz])["g"].append({"p": _encode(clean), "k": g["kind"]})

	_add_land_rects()
	_add_parking_spots()
	return skyline


## Half-on-the-pavement parking spots (as Casablanca drivers do, and it keeps
## the traffic lanes free) along car roads (not motorways), skipping the ends
## of each way, which are usually junctions. Stored per chunk as flat
## [x_dm, z_dm, yaw_milliradians, ...] under "s".
func _add_parking_spots() -> void:
	var count := 0
	for r in _roads:
		if r["cls"] == 0 or String(r["kind"]).begins_with("motorway") or r["kind"].ends_with("_link"):
			continue
		var pts: PackedVector2Array = r["pts"]
		var travelled := 0.0
		var next_spot := 15.0   # Leave the junction at the start of the way clear.
		var total := 0.0
		for i in pts.size() - 1:
			total += pts[i].distance_to(pts[i + 1])
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			var seg := a.distance_to(b)
			while next_spot <= travelled + seg and next_spot < total - 15.0:
				var dir := (b - a) / seg
				var right := Vector2(-dir.y, dir.x)   # Right-hand side of the road.
				var p: Vector2 = a.lerp(b, (next_spot - travelled) / seg) + right * (r["w"] * 0.5 + 0.6)
				if _is_land(p):
					var c := _chunk(_chunk_key(p))
					if not c.has("s"):
						c["s"] = []
					c["s"].append_array([roundi(p.x * DM), roundi(p.y * DM), roundi(atan2(dir.x, dir.y) * 1000.0)])
					count += 1
				next_spot += OsmConfig.PARKING_SPACING
			travelled += seg
	print("Parking spots: %d" % count)


func _add_road_run(key: String, run: PackedVector2Array, r: Dictionary) -> void:
	if run.size() >= 2:
		_chunk(key)["r"].append({"p": _encode(run), "w": roundi(r["w"] * DM), "c": r["cls"]})


func _subdivide(pts: PackedVector2Array, max_len: float) -> PackedVector2Array:
	var out := PackedVector2Array([pts[0]])
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var n := maxi(1, ceili(a.distance_to(b) / max_len))
		for s in range(1, n + 1):
			out.append(a.lerp(b, float(s) / n))
	return out


## Converts the land mask into as few rectangles as possible per chunk
## (row runs merged downwards), which become the walkable ground.
func _add_land_rects() -> void:
	var cell := OsmConfig.LAND_CELL
	var per_chunk := int(OsmConfig.CHUNK_SIZE / cell)
	var origin_c := (_bounds.position / OsmConfig.CHUNK_SIZE).floor()
	var end_c := (_bounds.end / OsmConfig.CHUNK_SIZE).floor()
	for cz in range(int(origin_c.y), int(end_c.y) + 1):
		for cx in range(int(origin_c.x), int(end_c.x) + 1):
			var rects := []      # [x0, z0, x1, z1] in metres
			var open := {}       # "x0_x1" -> index into rects, from the previous row
			for row in per_chunk:
				var z := (cz * per_chunk + row) * cell + cell * 0.5
				var runs := {}
				var col := 0
				while col < per_chunk:
					var x := (cx * per_chunk + col) * cell + cell * 0.5
					if not _is_land(Vector2(x, z)):
						col += 1
						continue
					var start := col
					while col < per_chunk and _is_land(Vector2((cx * per_chunk + col) * cell + cell * 0.5, z)):
						col += 1
					var x0 := (cx * per_chunk + start) * cell
					var x1 := (cx * per_chunk + col) * cell
					var k := "%d_%d" % [start, col]
					if open.has(k):
						rects[open[k]][3] = z + cell * 0.5
						runs[k] = open[k]
					else:
						rects.append([x0, z - cell * 0.5, x1, z + cell * 0.5])
						runs[k] = rects.size() - 1
				open = runs
			if rects.is_empty():
				continue
			var flat := []
			for r in rects:
				for v in r:
					flat.append(roundi(v * DM))
			_chunk("%d_%d" % [cx, cz])["l"] = flat


func _ring_bounds(ring: PackedVector2Array) -> Rect2:
	var r := Rect2(ring[0], Vector2.ZERO)
	for p in ring:
		r = r.expand(p)
	return r


func _encode(pts: PackedVector2Array) -> Array:
	var out := []
	for p in pts:
		out.append(roundi(p.x * DM))
		out.append(roundi(p.y * DM))
	return out


# --- Road graph (AI traffic and pedestrians) ------------------------------------

## Splits every road at junctions into graph edges. OSM ways that meet share a
## node, i.e. the exact same coordinates, so points are matched by position
## (rounded to 0.5 m). Written to traffic.json in decimetres:
##   nodes:   [x, z, ...]
##   edges:   [[a, b, class, kind, oneway, width, [x, z, ...]], ...]
##            kind 0 = walk only, 1 = street, 2 = fast road (no pedestrians)
##   signals: [node ids with traffic lights]
func _build_road_graph() -> Dictionary:
	var usage := {}
	for r in _roads:
		var pts: PackedVector2Array = r["pts"]
		for i in pts.size():
			var k := _point_key(pts[i])
			# Way ends always become nodes; shared points become junctions.
			usage[k] = usage.get(k, 0) + (2 if i == 0 or i == pts.size() - 1 else 1)

	_gnode_ids.clear()
	_gnode_pos.clear()
	var edges := []
	var edge_major := []     # Per edge: counts toward "major junction".
	for r in _roads:
		var pts: PackedVector2Array = r["pts"]
		var kind: String = r["kind"]
		var kind_code := 1
		if r["cls"] == 0:
			kind_code = 0
		elif kind.begins_with("motorway") or kind.begins_with("trunk"):
			kind_code = 2
		var a := _graph_node(pts[0])
		var cur := PackedVector2Array([pts[0]])
		for i in range(1, pts.size()):
			cur.append(pts[i])
			if usage[_point_key(pts[i])] < 2 and i < pts.size() - 1:
				continue
			var b := _graph_node(pts[i])
			if cur.size() >= 2 and _polyline_length(cur) > 0.5:
				edges.append([a, b, r["cls"], kind_code, r["oneway"], roundi(r["w"] * DM), _encode(cur)])
				edge_major.append(r["cls"] == 2 or kind.begins_with("tertiary"))
			cur = PackedVector2Array([pts[i]])
			a = b

	var node_pos := _gnode_pos
	# Degree and number of major roads at every junction.
	var degree := PackedInt32Array()
	var majors := PackedInt32Array()
	degree.resize(node_pos.size())
	majors.resize(node_pos.size())
	for i in edges.size():
		if edges[i][3] == 0:
			continue   # Footways don't make a junction need lights.
		for end in [edges[i][0], edges[i][1]]:
			degree[end] += 1
			if edge_major[i]:
				majors[end] += 1

	var candidates := []   # [score, node]
	if not _signal_points.is_empty():
		# Real lights from OSM, moved onto the junction they control.
		for sp in _signal_points:
			var best := -1
			var best_d := OsmConfig.SIGNAL_SNAP
			for n in node_pos.size():
				if degree[n] >= 3:
					var d := node_pos[n].distance_to(sp)
					if d < best_d:
						best_d = d
						best = n
			if best >= 0:
				candidates.append([degree[best], best])
	else:
		# A main road merely passing through counts 2 major arms; lights go
		# where main roads actually cross or meet (3+ major arms).
		for n in node_pos.size():
			if degree[n] >= 3 and majors[n] >= 3:
				candidates.append([degree[n] + majors[n], n])
	candidates.sort_custom(func(x, y): return x[0] > y[0])
	var signals := []
	var spacing := OsmConfig.SIGNAL_MIN_SPACING * (1.0 if not _signal_points.is_empty() else 1.8)
	for c in candidates:
		var ok := true
		for s in signals:
			if node_pos[s].distance_to(node_pos[c[1]]) < spacing:
				ok = false
				break
		if ok:
			signals.append(c[1])

	print("Road graph: %d junctions, %d roads, %d traffic lights (%s)." % [node_pos.size(), edges.size(),
		signals.size(), "from OSM" if not _signal_points.is_empty() else "major crossroads"])
	return {"nodes": _encode(node_pos), "edges": edges, "signals": signals}


func _point_key(p: Vector2) -> Vector2i:
	return Vector2i(roundi(p.x * 2.0), roundi(p.y * 2.0))


func _graph_node(p: Vector2) -> int:
	var k := _point_key(p)
	if not _gnode_ids.has(k):
		_gnode_ids[k] = _gnode_pos.size()
		_gnode_pos.append(p)
	return _gnode_ids[k]


func _polyline_length(pts: PackedVector2Array) -> float:
	var l := 0.0
	for i in pts.size() - 1:
		l += pts[i].distance_to(pts[i + 1])
	return l


# --- Manifest -----------------------------------------------------------------

func _make_manifest() -> Dictionary:
	var spawn := OsmConfig.project(OsmConfig.SPAWN_LAT, OsmConfig.SPAWN_LON)
	spawn = _snap_to_road(spawn, false)
	var yaw := _yaw_to_sea(spawn)

	var areas := []
	for i in OsmConfig.AREAS.size():
		var r := _area_rects[i]
		areas.append({"name": OsmConfig.AREAS[i]["name"],
			"rect": [r.position.x, r.position.y, r.end.x, r.end.y],
			"traffic": OsmConfig.AREAS[i].get("traffic", 1.0),
			"pedestrians": OsmConfig.AREAS[i].get("pedestrians", 1.0)})

	var keys := _chunks.keys()
	keys.sort()
	return {
		"version": 1,
		"units": "chunk files: decimetres; manifest: metres",
		"origin": {"lat": OsmConfig.ORIGIN_LAT, "lon": OsmConfig.ORIGIN_LON},
		"chunk_size": OsmConfig.CHUNK_SIZE,
		"bounds": [_bounds.position.x, _bounds.position.y, _bounds.end.x, _bounds.end.y],
		"chunks": keys,
		"spawn": {"pos": [spawn.x, 0.2, spawn.y], "yaw": yaw},
		"vehicle_spawns": _vehicle_spawns(spawn),
		"areas": areas,
		"attribution": "Map data © OpenStreetMap contributors (ODbL)",
	}


## Moves a point onto the nearest road/footway on land within 200 m.
func _snap_to_road(p: Vector2, cars_only: bool) -> Vector2:
	var best := p
	var best_d := 200.0
	for r in _roads:
		if cars_only and r["cls"] == 0:
			continue
		var pts: PackedVector2Array = r["pts"]
		for i in pts.size() - 1:
			var q := Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1])
			var d := q.distance_to(p)
			if d < best_d and _is_land(q):
				best_d = d
				best = q
	return best


## Yaw (radians, Godot +Z-forward convention) pointing at the nearest sea cell.
func _yaw_to_sea(p: Vector2) -> float:
	var best_d := INF
	var target := p + Vector2(0, -1)   # Default: face north.
	for z in _mask_h:
		for x in _mask_w:
			if _mask[z * _mask_w + x] != 2:
				continue
			var c := _bounds.position + Vector2(x + 0.5, z + 0.5) * OsmConfig.LAND_CELL
			var d := c.distance_squared_to(p)
			if d < best_d:
				best_d = d
				target = c
	var dir := target - p
	return atan2(dir.x, dir.y)


## Up to STARTER_VEHICLES parking spots on car roads 15-150 m from spawn, on the right-hand
## side of the road (Morocco drives on the right), facing along it.
func _vehicle_spawns(spawn: Vector2) -> Array:
	var candidates := []
	for r in _roads:
		if r["cls"] == 0:
			continue
		var pts: PackedVector2Array = r["pts"]
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			if a.distance_to(b) < 12.0:
				continue
			var mid := (a + b) * 0.5
			var d := mid.distance_to(spawn)
			if d < 15.0 or d > 150.0 or not _is_land(mid):
				continue
			var dir := (b - a).normalized()
			var right := Vector2(-dir.y, dir.x)   # (dir x UP) projected to x/z.
			var pos: Vector2 = mid + right * (r["w"] * 0.25)
			candidates.append({"d": d, "pos": pos, "yaw": atan2(dir.x, dir.y)})
	candidates.sort_custom(func(l, r): return l["d"] < r["d"])

	var picked := []
	for c in candidates:
		var ok := true
		for p in picked:
			if Vector2(p["pos"][0], p["pos"][2]).distance_to(c["pos"]) < 15.0:
				ok = false
				break
		if ok:
			picked.append({"pos": [c["pos"].x, 0.7, c["pos"].y], "yaw": c["yaw"]})
		if picked.size() == OsmConfig.STARTER_VEHICLES:
			break
	return picked


# --- Output -------------------------------------------------------------------

func _write(manifest: Dictionary, skyline: Array) -> void:
	var chunk_dir := _out_dir.path_join("chunks")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(chunk_dir))
	# Remove chunks from a previous import so nothing stale is streamed.
	var dir := DirAccess.open(chunk_dir)
	for f in dir.get_files():
		if f.ends_with(".json"):
			dir.remove(f)

	for key: String in _chunks:
		_save_json(chunk_dir.path_join(key + ".json"), _chunks[key])
	_save_json(_out_dir.path_join("skyline.json"), {"b": skyline})
	_save_json(_out_dir.path_join("manifest.json"), manifest, "\t")


func _save_json(path: String, data: Variant, indent := "") -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("Cannot write %s" % path)
		return
	f.store_string(JSON.stringify(data, indent, false))
