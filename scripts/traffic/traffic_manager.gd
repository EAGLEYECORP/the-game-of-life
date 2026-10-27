class_name TrafficManager
extends Node3D
## Runs the city's life: AI traffic, pedestrians and traffic lights.
##
## Built for performance:
##   - One manager loop drives every agent (no per-NPC _process callbacks).
##   - Movement runs each physics frame; decisions ("think") run ~10 times a
##     second, spread across frames so the cost is flat.
##   - Agents only exist in a ring around the player. They spawn out of sight
##     (or at the edge of it) and are recycled when they fall too far behind.
##   - "What's ahead of me?" uses a coarse spatial grid rebuilt once per frame.
##   - AI cars are kinematic with one baked mesh; pedestrians have no physics.
##   - Traffic light logic is a pure function of time; only the posts near the
##     player exist as nodes, and their lamps update 5 times a second.
##
## Density follows the district (see OsmConfig.AREAS: "traffic" and
## "pedestrians"): busy on the Corniche and downtown, few cars in the Medina.

## The player's car knocked someone down (for the wanted system).
signal pedestrian_hit(pos: Vector3)
## The player dragged a driver out of an AI car.
signal carjacked(pos: Vector3)

@export var streamer: ChunkStreamer
@export var player: Player

@export_group("Traffic")
@export var max_cars := 34               ## At density 1.0.
@export var car_spawn_min := 90.0        ## Spawn ring around the player (m).
@export var car_spawn_max := 240.0
@export var car_despawn := 300.0
## Vehicle scenes AI traffic is made of, and how common each is.
@export var car_scenes: Array[PackedScene] = []
@export var car_weights: PackedFloat32Array = []

@export_group("Pedestrians")
@export var max_pedestrians := 50        ## At density 1.0.
@export var ped_spawn_min := 45.0
@export var ped_spawn_max := 130.0
@export var ped_despawn := 160.0

@export_group("Traffic lights")
@export var light_radius := 220.0        ## Posts are built within this range.

const GRID := 12.0           # Spatial grid cell (m).
const THINK_RATE := 10.0     # Decisions per second per agent.

var graph: RoadGraph

var _cars: Array[TrafficCar] = []
var _peds: Array[Pedestrian] = []
var _converted: Array[Vehicle] = []     # Ex-traffic cars the player hijacked.
var _despawn_queue: Array[TrafficCar] = []
var _grid := {}                          # Vector2i -> Array of [pos, radius, node, is_player]
var _rng := RandomNumberGenerator.new()
var _time := 0.0
var _think_accum := 0.0
var _think_index := 0
var _spawn_timer := 0.0
var _light_timer := 0.0
var _posts := {}                         # node id -> Array of [Node3D, edge, lamps]
var _total_weight := 0.0
var _fill_ticks := 0
var _last_player_vehicle: Vehicle
var _police: Array[Node] = []            # Cached once per frame.


func _ready() -> void:
	_rng.randomize()
	for i in car_scenes.size():
		_total_weight += car_weights[i] if i < car_weights.size() else 1.0
	if player:
		player.vehicle_entered.connect(func(v: Vehicle) -> void: _last_player_vehicle = v)
	if streamer:
		streamer.initial_area_ready.connect(_load_graph, CONNECT_ONE_SHOT)


func _exit_tree() -> void:
	NpcVisuals.clear_cache()


## Loads the road graph: traffic.json from the OSM import, or the placeholder
## city's grid. Parsing a big city takes a moment, so it runs on a thread.
func _load_graph() -> void:
	var loaded: RoadGraph = null
	if streamer.has_data:
		var path := streamer.data_dir.path_join("traffic.json")
		if not FileAccess.file_exists(path):
			push_warning("No traffic.json: re-run the OSM import to get AI traffic.")
			return
		var holder := []
		var task := WorkerThreadPool.add_task(func() -> void:
			var d = JSON.parse_string(FileAccess.get_file_as_string(path))
			if typeof(d) == TYPE_DICTIONARY:
				holder.append(RoadGraph.from_dict(d, 0.1)))
		while not WorkerThreadPool.is_task_completed(task):
			await get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(task)
		loaded = holder[0] if not holder.is_empty() else null
	else:
		var city := streamer.get_fallback()
		if city and city.has_method("get_road_graph"):
			loaded = RoadGraph.from_dict(city.get_road_graph(), 1.0)
	if loaded:
		# Bake meshes first; nothing spawns until `graph` is set.
		await _prewarm()
		graph = loaded
		print("Traffic: road graph with %d junctions, %d roads, %d traffic lights."
			% [graph.nodes.size(), graph.edge_count(), graph.signals.size()])


## Bakes every vehicle type in every paint colour up front, one per frame, so
## spawning traffic later never stalls a frame.
func _prewarm() -> void:
	for scene in car_scenes:
		var probe := scene.instantiate() as Vehicle
		var colors: PackedColorArray = probe.paint_options if probe.randomize_paint else PackedColorArray([probe.paint_color])
		probe.free()
		for c in colors:
			NpcVisuals.vehicle_template(scene, c)
			await get_tree().process_frame


func _physics_process(delta: float) -> void:
	if graph == null or player == null:
		return
	_time += delta
	var focus := _focus_pos()

	_rebuild_grid()

	# Movement for everyone.
	for car in _cars:
		car.tick(delta)
	for ped in _peds:
		ped.tick(delta, ped.get_position_2d().distance_to(focus))

	# Decisions for a slice of agents this frame.
	_think_slice(delta)
	_check_rams()

	for car in _despawn_queue:
		_remove_car(car)
	_despawn_queue.clear()

	_spawn_timer -= delta
	if _spawn_timer <= 0.0:
		_spawn_timer = 0.25
		_manage_population(focus)

	_light_timer -= delta
	if _light_timer <= 0.0:
		_light_timer = 0.2
		_update_lights(focus)


# --- Queries used by agents -----------------------------------------------------

## Nearest thing in front of `me` within `reach` metres and `lane_half` metres
## sideways. Returns [distance, its radius, is_player] or [].
func obstacle_ahead(me: Node, pos: Vector2, dir: Vector2, reach: float, lane_half: float) -> Array:
	var best := []
	var best_d := reach
	var right := Vector2(-dir.y, dir.x)
	var mid := pos + dir * reach * 0.5
	var c0 := Vector2i(((mid - Vector2.ONE * reach * 0.5) / GRID).floor())
	var c1 := Vector2i(((mid + Vector2.ONE * reach * 0.5) / GRID).floor())
	for cx in range(c0.x, c1.x + 1):
		for cy in range(c0.y, c1.y + 1):
			var cell = _grid.get(Vector2i(cx, cy))
			if cell == null:
				continue
			for entry in cell:
				if entry[2] == me:
					continue
				var rel: Vector2 = entry[0] - pos
				var ahead := rel.dot(dir)
				if ahead <= 0.0 or ahead >= best_d:
					continue
				if absf(rel.dot(right)) > lane_half + entry[1]:
					continue
				best_d = ahead
				best = [ahead, entry[1], entry[3]]
	return best


## Makes pedestrians near `pos` run (someone got knocked over, a crash...).
func scare_pedestrians(pos: Vector2, radius: float) -> void:
	for ped in _peds:
		if ped.get_position_2d().distance_to(pos) < radius:
			ped.scare(pos)


## True if a police car with its siren on is within `radius` of `pos`.
func siren_near(pos: Vector3, radius: float) -> bool:
	for v in _police:
		if is_instance_valid(v) and v.siren_on and v.global_position.distance_to(pos) < radius:
			return true
	return false


func request_despawn(car: TrafficCar) -> void:
	if not car in _despawn_queue:
		_despawn_queue.append(car)


## Replaces an AI car with a real drivable Vehicle in the same spot, and drops
## its driver on the pavement running away. Used for carjacking.
func convert_to_vehicle(car: TrafficCar) -> Vehicle:
	carjacked.emit(car.global_position)
	var scene: PackedScene = car.template["scene"]
	var v := scene.instantiate() as Vehicle
	v.randomize_paint = false
	v.paint_color = car.paint
	v.spawned = true
	add_child(v)
	var t := car.global_transform
	v.global_transform = t
	v.linear_velocity = t.basis.z * car.speed
	_converted.append(v)

	# The driver bails out of the door and legs it.
	var door := car.get_door_position()
	_remove_car(car)
	var spot := graph.random_spot(Vector2(door.x, door.z), 0.0, 25.0, _rng, true)
	if not spot.is_empty():
		var ped := _spawn_ped(spot)
		ped._pos = Vector2(door.x, door.z)
		ped.scare(Vector2(t.origin.x, t.origin.z))
	return v


# --- Population -----------------------------------------------------------------

func _focus_pos() -> Vector2:
	var p := player.global_position
	return Vector2(p.x, p.z)


func _density(pos: Vector2, key: String) -> float:
	return streamer.get_area_value(Vector3(pos.x, 0, pos.y), key, 1.0)


func _manage_population(focus: Vector2) -> void:
	# Recycle agents that are far behind.
	for i in range(_cars.size() - 1, -1, -1):
		if _cars[i].global_position.distance_to(Vector3(focus.x, 0, focus.y)) > car_despawn:
			_remove_car(_cars[i])
	for i in range(_peds.size() - 1, -1, -1):
		if _peds[i].get_position_2d().distance_to(focus) > ped_despawn:
			_peds[i].queue_free()
			_peds.remove_at(i)
	for i in range(_converted.size() - 1, -1, -1):
		var v := _converted[i]
		if not is_instance_valid(v):
			_converted.remove_at(i)
		elif not v.has_driver() and v != _last_player_vehicle \
				and v.global_position.distance_to(Vector3(focus.x, 0, focus.y)) > car_despawn:
			v.queue_free()
			_converted.remove_at(i)

	# Top up to the local density. For the first couple of seconds, fill the
	# whole ring (closer in too) in batches so the city starts alive without
	# one giant spawn frame.
	_fill_ticks += 1
	var filling := _fill_ticks <= 8
	var tries := 10 if filling else 3
	var car_min := 25.0 if filling else car_spawn_min
	var ped_min := 8.0 if filling else ped_spawn_min

	var want_cars := int(max_cars * _density(focus, "traffic"))
	for i in tries:
		if _cars.size() >= want_cars:
			break
		var spot := graph.random_spot(focus, car_min, car_spawn_max, _rng, false)
		if spot.is_empty():
			continue
		# Spot density decides too, so quiet streets stay quiet even when the
		# player stands somewhere busy.
		if _rng.randf() > _density(_spot_pos(spot), "traffic") / 1.6:
			continue
		_spawn_car(spot)

	var want_peds := int(max_pedestrians * _density(focus, "pedestrians"))
	for i in tries:
		if _peds.size() >= want_peds:
			break
		var spot := graph.random_spot(focus, ped_min, ped_spawn_max, _rng, true)
		if spot.is_empty() or _rng.randf() > _density(_spot_pos(spot), "pedestrians") / 1.6:
			continue
		_spawn_ped(spot)


## Centre-line position of a [edge, from_node, along] spot.
func _spot_pos(spot: Array) -> Vector2:
	var e: int = spot[0]
	var along: float = spot[2] if spot[1] == graph.edge_a[e] else graph.edge_length[e] - spot[2]
	return graph.point_along(e, along)


func _spawn_car(spot: Array) -> void:
	# Never spawn on top of another agent.
	var cell = _grid.get(Vector2i((_spot_pos(spot) / GRID).floor()))
	if cell != null and not cell.is_empty():
		return
	var scene := _pick_scene()
	var paint := NpcVisuals.random_paint(scene, _rng)
	var car := TrafficCar.new()
	add_child(car)
	car.setup(self, graph, NpcVisuals.vehicle_template(scene, paint), paint, spot)
	_cars.append(car)


func _spawn_ped(spot: Array) -> Pedestrian:
	var ped := Pedestrian.new()
	add_child(ped)
	ped.setup(self, graph, spot)
	_peds.append(ped)
	return ped


func _remove_car(car: TrafficCar) -> void:
	_cars.erase(car)
	if is_instance_valid(car):
		car.queue_free()


func _pick_scene() -> PackedScene:
	var roll := _rng.randf() * _total_weight
	for i in car_scenes.size():
		roll -= car_weights[i] if i < car_weights.size() else 1.0
		if roll <= 0.0:
			return car_scenes[i]
	return car_scenes[-1]


# --- Per-frame helpers ------------------------------------------------------------

## Everyone's position in a coarse grid, for obstacle checks.
func _rebuild_grid() -> void:
	_grid.clear()
	for car in _cars:
		var p := car.global_position
		_grid_add(Vector2(p.x, p.z), car.half_width, car, false)
	for ped in _peds:
		_grid_add(ped.get_position_2d(), 0.4, ped, false)
	# The player, on foot or driving, plus parked/converted vehicles on roads.
	var pv := player.current_vehicle
	var pp := player.global_position
	_grid_add(Vector2(pp.x, pp.z), 1.0 if pv else 0.5, pv if pv else player, true)
	# Police cars (real physics vehicles): traffic must not drive into them.
	_police = get_tree().get_nodes_in_group("police")
	for v in _police:
		_grid_add(Vector2(v.global_position.x, v.global_position.z), 1.0, v, false)
	for v in _converted:
		if is_instance_valid(v) and v != pv:
			_grid_add(Vector2(v.global_position.x, v.global_position.z), 1.0, v, false)


func _grid_add(p: Vector2, radius: float, node: Node, is_player: bool) -> void:
	var cell := Vector2i((p / GRID).floor())
	if not _grid.has(cell):
		_grid[cell] = []
	_grid[cell].append([p, radius, node, is_player])


## Runs think() for 1/N of the agents each frame, N = physics rate / THINK_RATE.
func _think_slice(delta: float) -> void:
	var total := _cars.size() + _peds.size()
	if total == 0:
		return
	var per_frame := ceili(total * THINK_RATE * delta)
	var pv := player.current_vehicle
	var player_on_foot := Vector2.INF if pv else _focus_pos()
	var car_pos := Vector2.INF
	var car_vel := Vector2.ZERO
	if pv:
		car_pos = Vector2(pv.global_position.x, pv.global_position.z)
		car_vel = Vector2(pv.linear_velocity.x, pv.linear_velocity.z)
	for i in per_frame:
		_think_index = (_think_index + 1) % total
		if _think_index < _cars.size():
			_cars[_think_index].think(_time)
		else:
			_peds[_think_index - _cars.size()].think(player_on_foot, car_pos, car_vel)


## Player's car slamming into AI cars makes them panic (and scares people).
func _check_rams() -> void:
	var pv := player.current_vehicle
	if pv == null or pv.linear_velocity.length() < 4.0:
		return
	var p := Vector2(pv.global_position.x, pv.global_position.z)
	var v := Vector2(pv.linear_velocity.x, pv.linear_velocity.z)
	var c0 := Vector2i((p / GRID).floor())
	for cx in range(c0.x - 1, c0.x + 2):
		for cy in range(c0.y - 1, c0.y + 2):
			for entry in _grid.get(Vector2i(cx, cy), []):
				var car := entry[2] as TrafficCar
				if car == null or car.state == TrafficCar.State.PANIC:
					continue
				# Touching (bumper to bumper) and closing in fast enough to hurt.
				var rel: Vector2 = entry[0] - p
				var closing := (v - car.velocity_2d()).dot(rel.normalized())
				if rel.length() < car.length * 0.5 + 3.0 and closing > 3.0:
					car.on_rammed()
					scare_pedestrians(p, 12.0)


# --- Traffic lights ---------------------------------------------------------------

## Builds posts for signalled junctions near the player, frees far ones, and
## sets each lamp to the current light state.
func _update_lights(focus: Vector2) -> void:
	var near := graph.signals_near(focus, light_radius)
	var keep := {}
	for n in near:
		keep[n] = true
		if not _posts.has(n):
			_posts[n] = _build_posts(n)
	for n: int in _posts.keys():
		if not keep.has(n) and graph.nodes[n].distance_to(focus) > light_radius + 40.0:
			for post in _posts[n]:
				post[0].queue_free()
			_posts.erase(n)

	var mats := NpcVisuals.lamp_materials()
	for n: int in _posts:
		for post in _posts[n]:
			var state := graph.light_at(n, post[1], _time)
			var lamps: Array = post[2]
			# Lamp 0 red, 1 amber, 2 green.
			lamps[0].material_override = mats[1 if state == RoadGraph.Light.RED else 0]
			lamps[1].material_override = mats[3 if state == RoadGraph.Light.YELLOW else 2]
			lamps[2].material_override = mats[5 if state == RoadGraph.Light.GREEN else 4]


## One post per road arriving at the junction, on its right-hand kerb, facing
## the oncoming drivers.
func _build_posts(n: int) -> Array:
	var posts := []
	var center := graph.nodes[n]
	for e in graph.node_edges[n]:
		if not graph.is_drivable(e) or not graph.signals[n].has(e):
			continue
		# Direction of travel *towards* the junction along this edge.
		var pts := graph.edge_points[e]
		var away := (pts[1] - pts[0]) if graph.edge_a[e] == n else (pts[-2] - pts[-1])
		away = away.normalized()
		var toward := -away
		var right := Vector2(-toward.y, toward.x)
		var w := graph.edge_width[e]
		var p := center + away * (w * 0.5 + 4.0) + right * (w * 0.5 + 0.8)
		var post := Node3D.new()
		add_child(post)
		post.position = Vector3(p.x, 0.0, p.y)
		# Lamps face +Z of the post; turn them toward approaching traffic.
		post.rotation.y = atan2(-toward.x, -toward.y)
		posts.append([post, e, NpcVisuals.build_traffic_light(post)])
	return posts
