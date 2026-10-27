class_name ChunkStreamer
extends Node3D
## Streams the imported OpenStreetMap city in and out around a focus node.
##
## On start it reads manifest.json (spawn point, chunk list...). Every few
## frames it compares the chunks near the focus with what's loaded:
##   - chunks within `load_radius` are built on worker threads (file read,
##     JSON parse, triangulation) and then added on the main thread a couple
##     per frame, so there are no big hitches;
##   - chunks beyond `unload_radius` are freed. The gap between the two radii
##     stops chunks flickering in and out at the border.
## The skyline (very tall buildings like the Hassan II minaret) is loaded once
## and never unloaded, so it's visible from anywhere.
##
## If no imported data exists yet, the procedural placeholder city is used
## instead, so the game always runs.

## Emitted once the chunks around the first focus position are in place.
## Until then nothing should rely on the ground existing.
signal initial_area_ready
## A chunk finished loading. `spots` are its parking spots ({pos, yaw}) for
## VehicleSpawner. With the placeholder city, sent once with key "fallback".
signal chunk_loaded(key: String, spots: Array)
## A chunk was freed; anything standing on it has no ground any more.
signal chunk_unloaded(key: String)

@export_dir var data_dir := "res://maps/casablanca_osm"
@export var load_radius := 500.0    ## Metres around the focus to keep loaded.
@export var unload_radius := 700.0  ## Chunks further than this are freed.
@export var max_chunks_per_frame := 2
## Scene used when there's no imported OSM data.
@export var fallback_scene: PackedScene
## Sea plane that follows the focus so the ocean looks endless.
@export var sea: Node3D

## true when OSM data was found and is being streamed.
var has_data := false
## Data from manifest.json (spawn, vehicle_spawns, areas, ...).
var manifest := {}

var _focus: Node3D
var _chunk_size := 200.0
var _available := {}       # Chunk key -> true for every chunk on disk.
var _loaded := {}          # Chunk key -> Node3D
var _pending := {}         # Chunk key -> WorkerThreadPool task id
var _finished: Array = []  # [key, ChunkBuilder.Result], filled by worker threads
var _mutex := Mutex.new()
var _material: StandardMaterial3D
var _initial_done := false
var _update_timer := 0.0
var _fallback: Node = null


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.vertex_color_is_srgb = true
	_material.roughness = 0.9

	var manifest_path := data_dir.path_join("manifest.json")
	if FileAccess.file_exists(manifest_path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
		if typeof(parsed) == TYPE_DICTIONARY:
			manifest = parsed
			has_data = true
			_chunk_size = manifest.get("chunk_size", 200.0)
			for key in manifest.get("chunks", []):
				_available[key] = true

	if not has_data:
		push_warning("No OSM data in %s - using the placeholder city. See README to import Casablanca." % data_dir)
		if fallback_scene:
			_fallback = fallback_scene.instantiate()
			add_child(_fallback)
		if sea:
			sea.visible = false
	else:
		_start_task("__skyline", data_dir.path_join("skyline.json"))


## Starts streaming around `node` (the player). Call after moving it to spawn.
func set_focus(node: Node3D) -> void:
	_focus = node
	_update_timer = 0.0
	if not has_data:
		_emit_ready.call_deferred()


func _exit_tree() -> void:
	# Worker threads must finish before this node (and its data) goes away.
	for key in _pending:
		WorkerThreadPool.wait_for_task_completion(_pending[key])
	_pending.clear()


func _process(delta: float) -> void:
	if not has_data or _focus == null:
		return

	_update_timer -= delta
	if _update_timer <= 0.0:
		_update_timer = 0.25
		_update_wanted()

	_finalize_finished()

	if sea:
		# Snap to a 50 m grid so the sea's surface doesn't visibly slide.
		var p := _focus.global_position.snapped(Vector3(50, 0, 50))
		sea.global_position = Vector3(p.x, sea.global_position.y, p.z)

	if not _initial_done and _pending.is_empty() and _finished.is_empty():
		_initial_done = true
		initial_area_ready.emit()


# --- Public queries -----------------------------------------------------------

## True if the ground under `pos` is loaded (or there is no data there at all).
## Used to freeze parked cars that would otherwise fall through the world.
func is_loaded_at(pos: Vector3) -> bool:
	if not has_data:
		return true
	var key := _key_at(pos)
	return _loaded.has(key) or not _available.has(key)


## Chunk key for a world position (same keys as chunk_loaded/unloaded).
func key_at(pos: Vector3) -> String:
	return _key_at(pos) if has_data else "fallback"


## A per-district number from the manifest (e.g. "traffic" or "pedestrians"
## density), or `default` outside every district / without OSM data.
func get_area_value(pos: Vector3, key: String, default: float) -> float:
	for area in manifest.get("areas", []):
		var r: Array = area["rect"]
		if pos.x >= r[0] and pos.x <= r[2] and pos.z >= r[1] and pos.z <= r[3]:
			return area.get(key, default)
	return default


## The placeholder city node when running without OSM data, else null.
func get_fallback() -> Node:
	return _fallback


## Name of the district containing `pos`, or "" outside every area.
func get_area_name(pos: Vector3) -> String:
	for area in manifest.get("areas", []):
		var r: Array = area["rect"]
		if pos.x >= r[0] and pos.x <= r[2] and pos.z >= r[1] and pos.z <= r[3]:
			return area["name"]
	return ""


# --- Streaming ----------------------------------------------------------------

func _key_at(pos: Vector3) -> String:
	return "%d_%d" % [floori(pos.x / _chunk_size), floori(pos.z / _chunk_size)]


## Distance from `pos` to the nearest point of chunk (cx, cz).
func _chunk_distance(cx: int, cz: int, pos: Vector3) -> float:
	var rect := Rect2(cx * _chunk_size, cz * _chunk_size, _chunk_size, _chunk_size)
	var p := Vector2(pos.x, pos.z)
	return p.distance_to(p.clamp(rect.position, rect.end))


func _update_wanted() -> void:
	var pos := _focus.global_position
	var center := Vector2i(floori(pos.x / _chunk_size), floori(pos.z / _chunk_size))
	var reach := ceili(load_radius / _chunk_size)

	# Queue missing chunks, nearest first, so the ground under you comes first.
	var wanted := []
	for cz in range(center.y - reach, center.y + reach + 1):
		for cx in range(center.x - reach, center.x + reach + 1):
			var key := "%d_%d" % [cx, cz]
			if not _available.has(key) or _loaded.has(key) or _pending.has(key):
				continue
			var d := _chunk_distance(cx, cz, pos)
			if d <= load_radius:
				wanted.append([d, key])
	wanted.sort_custom(func(a, b): return a[0] < b[0])
	for w in wanted:
		_start_task(w[1], data_dir.path_join("chunks/%s.json" % w[1]))

	# Free chunks that are now far away.
	for key: String in _loaded.keys():
		var c := key.split("_")
		if _chunk_distance(int(c[0]), int(c[1]), pos) > unload_radius:
			_loaded[key].queue_free()
			_loaded.erase(key)
			chunk_unloaded.emit(key)


func _start_task(key: String, path: String) -> void:
	_pending[key] = WorkerThreadPool.add_task(_build_task.bind(key, path), false, "chunk " + key)


## Runs on a worker thread. Must not touch the scene tree.
func _build_task(key: String, path: String) -> void:
	var result: ChunkBuilder.Result = null
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) == TYPE_DICTIONARY:
		result = ChunkBuilder.build(data)
	_mutex.lock()
	_finished.append([key, result])
	_mutex.unlock()


## Main thread: turns finished build results into nodes, a few per frame.
func _finalize_finished() -> void:
	for i in max_chunks_per_frame:
		_mutex.lock()
		var item = _finished.pop_front() if not _finished.is_empty() else null
		_mutex.unlock()
		if item == null:
			return
		var key: String = item[0]
		var result: ChunkBuilder.Result = item[1]
		WorkerThreadPool.wait_for_task_completion(_pending[key])
		_pending.erase(key)
		if result == null:
			push_warning("Could not read map chunk %s" % key)
			continue
		var node := _make_chunk_node(key, result)
		add_child(node)
		if key != "__skyline":
			_loaded[key] = node
			chunk_loaded.emit(key, result.spots)


func _make_chunk_node(key: String, result: ChunkBuilder.Result) -> Node3D:
	var body := StaticBody3D.new()
	body.name = "Chunk_" + key
	body.collision_layer = 1
	body.collision_mask = 0

	if not result.verts.is_empty():
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, result.mesh_arrays())
		mesh.surface_set_material(0, _material)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		body.add_child(mi)

	if not result.collision.is_empty():
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(result.collision)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
	return body


func _emit_ready() -> void:
	if not _initial_done:
		_initial_done = true
		if _fallback and _fallback.has_method("get_parking_spots"):
			chunk_loaded.emit("fallback", _fallback.get_parking_spots())
		initial_area_ready.emit()
