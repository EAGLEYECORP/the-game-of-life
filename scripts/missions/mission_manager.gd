class_name MissionManager
extends Node3D
## Runs story missions, the Petit Taxi side job and Youssef's garage.
##
## Missions are data (MissionData): lists of steps run one after another by a
## small state machine here. Places are resolved on the road graph when needed,
## so the same missions work on the real OSM map and the placeholder city.
##
##   - Contacts stand at yellow markers (Y, H, R). Walk into one to start
##     their next mission.
##   - The current objective has a marker, a minimap blip and a GPS route.
##   - Missions fail if you're busted, run out of time, wreck the cargo or
##     abandon the mission vehicle; walk back into the marker to retry.
##   - In any Petit Taxi, press J for taxi fares: pick up, drop off, get paid
##     by distance with a tip for speed, less for every crash.
##   - Drive into Youssef's garage (green G) to repair (150 DH) or, if the
##     police have lost sight of you, respray to lose your wanted level (250 DH).

signal mission_started(title: String)
signal mission_ended(title: String, passed: bool)

@export var player: Player
@export var traffic: TrafficManager
@export var streamer: ChunkStreamer
@export var wanted: WantedSystem
@export var police: PoliceManager
@export var wallet: Wallet
@export var hud: HUD

const REPAIR_COST := 150
const RESPRAY_COST := 250
const LINE_TIME := 3.4          # Seconds per dialogue line.
const ABANDON_TIME := 15.0      # Seconds away from the mission vehicle before failing.

## Mission ids already completed (saved).
var completed: Array = []
## The mission being played (MissionData entry), or {} when free roaming.
var active := {}
var taxi_job := false

var _ready_world := false
var _rng := RandomNumberGenerator.new()
var _points := {}               # Named places: "garage", saved step points...
var _contacts := {}             # contact id -> {pos, marker}
var _garage_service: MissionMarker
var _garage_inside := false

var _step := -1
var _step_time := 0.0
var _step_data := {}
var _objective: MissionMarker
var _objective_pos := Vector3.INF
var _vehicles := {}             # id -> Vehicle, or pending {scene, pos, yaw, locked}
var _npc: MissionNpc
var _passenger_aboard := false
var _time_limit := -1.0         # Seconds left on a timed step, -1 = none.
var _abandon_time := 0.0
var _race_points: Array[Vector3] = []
var _race_marker_next: MissionMarker
var _cooldown := 0.0
var _route := PackedVector2Array()
var _route_timer := 0.0
var _route_target := Vector3.INF
var _fare_crashes := 0


func _ready() -> void:
	_rng.seed = 1907            # Same contact spots every session on the same map.
	completed = SaveGame.load_data().get("missions", [])
	if police:
		police.busted.connect(func() -> void: _fail("BUSTED"))
	if player:
		player.vehicle_entered.connect(_on_vehicle_entered)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("job_toggle") and active.is_empty():
		var v := player.current_vehicle
		if taxi_job:
			_end_taxi_job("Taxi job ended")
		elif v and v.display_name == "Petit Taxi":
			get_viewport().set_input_as_handled()
			_start_taxi_job()


func _process(delta: float) -> void:
	if not _ready_world:
		if traffic and traffic.graph:
			_setup_world()
		return
	_cooldown = maxf(_cooldown - delta, 0.0)
	_spawn_pending_vehicles()
	_update_garage()
	if active.is_empty():
		_check_contacts()
	else:
		_update_step(delta)
		_check_failures(delta)
	_update_route(delta)


# --- Public API for HUD / minimap --------------------------------------------------

## Blips for the minimap: [{pos: Vector3, kind: String, letter: String}].
func blips() -> Array:
	var out := []
	if active.is_empty():
		for id in _contacts:
			if _contacts[id]["marker"]:
				out.append({"pos": _contacts[id]["pos"], "kind": "mission", "letter": MissionData.CONTACTS[id]["letter"]})
	if _garage_service:
		out.append({"pos": _garage_service.global_position, "kind": "garage", "letter": "G"})
	if _objective_pos != Vector3.INF:
		out.append({"pos": _objective_pos, "kind": "objective", "letter": ""})
	return out


## GPS route to the current objective, in world x/z (empty = none).
func route() -> PackedVector2Array:
	return _route


func has_mission() -> bool:
	return not active.is_empty()


# --- World setup -------------------------------------------------------------------

func _setup_world() -> void:
	_ready_world = true
	_points["garage"] = _road_spot(_v2(player.global_position), 25.0, 70.0)["pos"]
	var g: Dictionary = _road_spot(_v2(_points["garage"]), 10.0, 25.0)
	_garage_service = MissionMarker.create(self, g["kerb"], "garage", "G", 4.0)
	for id in MissionData.CONTACTS:
		var c: Dictionary = MissionData.CONTACTS[id]
		_contacts[id] = {"pos": _resolve(c["loc"]), "marker": null}
	_refresh_contacts()


## Shows a marker for each contact who has a mission available.
func _refresh_contacts() -> void:
	for id in _contacts:
		var want := _next_mission_for(id) != {} and active.is_empty()
		var marker: MissionMarker = _contacts[id]["marker"]
		if want and marker == null:
			_contacts[id]["marker"] = MissionMarker.create(self, _contacts[id]["pos"], "mission",
				MissionData.CONTACTS[id]["letter"], 2.0)
		elif not want and marker:
			marker.queue_free()
			_contacts[id]["marker"] = null


func _next_mission_for(contact: String) -> Dictionary:
	for m in MissionData.MISSIONS:
		if m["contact"] != contact or m["id"] in completed:
			continue
		var ok := true
		for r in m["requires"]:
			if not r in completed:
				ok = false
		if ok:
			return m
	return {}


func _check_contacts() -> void:
	if _cooldown > 0.0 or player.current_vehicle or taxi_job:
		return
	for id in _contacts:
		var marker: MissionMarker = _contacts[id]["marker"]
		if marker and marker.contains(player.global_position):
			_start_mission(_next_mission_for(id))
			return


# --- Running missions ---------------------------------------------------------------

func _start_mission(m: Dictionary) -> void:
	active = m
	_vehicles.clear()
	_refresh_contacts()
	hud.show_banner(m["title"], MissionData.CONTACTS[m["contact"]]["name"])
	mission_started.emit(m["title"])
	_step = -1
	_next_step()


func _next_step() -> void:
	_clear_objective()
	_time_limit = -1.0
	_step += 1
	var steps: Array = active["steps"]
	if _step >= steps.size():
		if taxi_job:
			_queue_fare()     # Fare delivered: straight on to the next one.
		else:
			_pass()
		return
	# Copy: mission data is constant, and steps keep per-run notes.
	_step_data = steps[_step].duplicate(true)
	_step_time = 0.0
	_start_step(_step_data)


func _start_step(s: Dictionary) -> void:
	hud.set_objective(s.get("text", ""))
	match s["type"]:
		"talk":
			hud.show_subtitle(s["lines"][0], LINE_TIME)
		"spawn_vehicle":
			var spot := _resolve_spot(s["loc"])
			_vehicles[s["id"]] = {"scene": "res://scenes/vehicles/%s.tscn" % s["scene"],
				"pos": spot["kerb"], "yaw": spot["yaw"], "locked": s.get("locked", false)}
			_next_step.call_deferred()
		"enter_vehicle":
			pass
		"goto":
			_set_objective(_save_point(s, _resolve(s["loc"])), 5.0, "objective")
		"pickup":
			var spot := _resolve_spot(s["loc"])
			_save_point(s, spot["pos"])
			if _npc:
				_npc.queue_free()
			_npc = MissionNpc.create(self, spot["pos"], _rng.randi())
			_npc.set_waving(true)
			_npc.face(spot["kerb"])
			_passenger_aboard = false
			_set_objective(spot["kerb"], 7.0, "taxi")
		"dropoff":
			var spot := _resolve_spot(s["loc"])
			_save_point(s, spot["pos"])
			_set_objective(spot["kerb"], 7.0, "taxi")
			if s.get("timed", false):
				var dist := _v2(player.global_position).distance_to(_v2(spot["kerb"]))
				_time_limit = dist / 7.0 + 25.0
		"wait":
			pass
		"add_wanted":
			wanted.heat = maxf(wanted.heat, float(s["stars"]))
			wanted.report_crime("break_in", player.global_position)
			_next_step.call_deferred()
		"lose_wanted":
			pass
		"race":
			_build_race(int(s["checkpoints"]), float(s["spacing"]))


func _update_step(delta: float) -> void:
	_step_time += delta
	if _time_limit >= 0.0:
		_time_limit -= delta
		hud.set_timer(_time_limit)
		if _time_limit <= 0.0:
			_fail("Out of time")
			return
	var s := _step_data
	var v := player.current_vehicle
	match s.get("type", ""):
		"talk":
			var lines: Array = s["lines"]
			var i := int(_step_time / LINE_TIME)
			if i >= lines.size():
				_next_step()
			elif int((_step_time - delta) / LINE_TIME) != i:
				hud.show_subtitle(lines[i], LINE_TIME)
		"enter_vehicle":
			var target = _vehicles.get(s.get("id", ""))
			var got: bool = v != null and (v == target or s.get("any_vehicle", false))
			if got:
				_next_step()
			elif target is Vehicle:
				_objective_pos = target.global_position
			elif target is Dictionary:
				_objective_pos = target["pos"]
		"goto":
			var need = _vehicles.get(s.get("vehicle", "")) if s.has("vehicle") else null
			if need is Vehicle and v != need:
				hud.set_objective("Get back in the %s" % need.display_name)
				_objective_pos = need.global_position
				return
			hud.set_objective(s.get("text", ""))
			if _objective:
				_objective_pos = _objective.global_position
				if _objective.contains(player.global_position):
					_next_step()
		"pickup":
			_update_pickup(v)
		"dropoff":
			_update_dropoff(v)
		"wait":
			hud.set_objective("%s %d" % [s.get("text", "Wait"), ceili(s["seconds"] - _step_time)])
			if _step_time >= s["seconds"]:
				_next_step()
		"lose_wanted":
			_objective_pos = Vector3.INF
			if wanted.stars == 0:
				_next_step()
		"race":
			_update_race()


func _update_pickup(v: Vehicle) -> void:
	if _passenger_aboard:
		return
	if v == null:
		hud.set_objective("Get in a vehicle to pick up the passenger")
		return
	hud.set_objective(_step_data.get("text", "Pick up the passenger"))
	if _objective and _objective.contains(v.global_position) and v.get_speed_kmh() < 8.0:
		# Stop, and they walk over and get in.
		_passenger_aboard = true
		_npc.set_waving(false)
		_npc.walk_to(v.get_door_position())
		_npc.arrived.connect(func() -> void:
			_npc.visible = false
			_next_step(), CONNECT_ONE_SHOT)


func _update_dropoff(v: Vehicle) -> void:
	if v == null:
		hud.set_objective("Get back in the vehicle, your passenger is waiting")
		return
	if _objective and _objective.contains(v.global_position) and v.get_speed_kmh() < 8.0:
		var door := v.get_door_position()
		_npc.global_position = door
		_npc.visible = true
		_npc.walk_to(_points.get(_step_data.get("save_as", ""), door + (door - v.global_position).normalized() * 4.0))
		var leaving := _npc
		_npc = null
		get_tree().create_timer(5.0).timeout.connect(func() -> void:
			if is_instance_valid(leaving):
				leaving.queue_free())
		if taxi_job:
			_pay_fare()
		_next_step()


## Race checkpoints: follow the roads from the player's junction, preferring
## to carry straight on, one checkpoint every `spacing` metres.
func _build_race(count: int, spacing: float) -> void:
	var g := traffic.graph
	var node := g.nearest_node(_v2(player.global_position))
	var prev_dir := Vector2.ZERO
	var from_e := -1
	var pts: Array[Vector3] = []
	var carry := 0.0
	var total := 0.0
	for hop in 200:
		var best := -1
		var best_score := -INF
		for e in g.node_edges[node]:
			if e == from_e or not g.is_drivable(e):
				continue
			var p := g.edge_points[e]
			var dir := ((p[1] - p[0]) if g.edge_a[e] == node else (p[-2] - p[-1])).normalized()
			var score := dir.dot(prev_dir) + g.edge_class[e] * 0.3 + _rng.randf() * 0.2
			if score > best_score:
				best_score = score
				best = e
		if best < 0:
			break
		var along_from_a := g.edge_a[best] == node
		var length := g.edge_length[best]
		var d := spacing - carry
		while d <= length and pts.size() < count:
			var p := g.point_along(best, d if along_from_a else length - d)
			pts.append(Vector3(p.x, 0.1, p.y))
			d += spacing
		carry = length - (d - spacing)
		total += length
		var ep := g.edge_points[best]
		prev_dir = ((ep[-1] - ep[-2]) if along_from_a else (ep[0] - ep[1])).normalized()
		from_e = best
		node = g.other_end(best, node)
		if pts.size() >= count:
			break
	_race_points = pts
	_time_limit = pts.size() * spacing / 13.0 + 12.0
	_show_race_markers()


func _show_race_markers() -> void:
	_clear_objective()
	if _race_marker_next:
		_race_marker_next.queue_free()
		_race_marker_next = null
	if _race_points.is_empty():
		return
	_set_objective(_race_points[0], 9.0, "checkpoint")
	if _race_points.size() > 1:
		_race_marker_next = MissionMarker.create(self, _race_points[1], "checkpoint", "", 6.0)
		_race_marker_next.scale = Vector3.ONE * 0.6


func _update_race() -> void:
	if player.current_vehicle == null:
		hud.set_objective("Get back in a car!")
		return
	hud.set_objective("%s  (%d left)" % [_step_data.get("text", ""), _race_points.size()])
	if _objective and _objective.contains(player.current_vehicle.global_position):
		_race_points.remove_at(0)
		if _race_points.is_empty():
			if _race_marker_next:
				_race_marker_next.queue_free()
				_race_marker_next = null
			_next_step()
		else:
			_show_race_markers()


func _check_failures(delta: float) -> void:
	if taxi_job:
		if player.current_vehicle == null and _step >= 0:
			_end_taxi_job("You left the taxi: job over")
		return
	var limit: float = active.get("min_condition", -1.0)
	var keep: String = active.get("keep_vehicle", "")
	var mv = _vehicles.get(keep)
	if keep != "" and mv != null and not mv is Dictionary:
		if not is_instance_valid(mv):
			_fail("The vehicle is gone")
			return
		var dmg := mv.get_node_or_null("Damage") as VehicleDamage
		if limit > 0.0 and dmg and dmg.condition < limit:
			_fail("The cargo is wrecked")
			return
		if player.current_vehicle != mv and player.global_position.distance_to(mv.global_position) > 60.0:
			_abandon_time += delta
			if _abandon_time > ABANDON_TIME:
				_fail("You abandoned the %s" % mv.display_name)
		else:
			_abandon_time = 0.0


func _pass() -> void:
	var m := active
	var reward: int = m.get("reward", 0)
	if not m["id"] in completed:
		completed.append(m["id"])
		SaveGame.store({"missions": completed})
	wallet.earn(reward, m["title"])
	hud.show_banner("MISSION PASSED", "+" + Wallet.format(reward))
	mission_ended.emit(m["title"], true)
	_cleanup()


func _fail(reason: String) -> void:
	if active.is_empty() and not taxi_job:
		return
	if taxi_job:
		_end_taxi_job(reason)
		return
	var m := active
	hud.show_banner("MISSION FAILED", reason)
	mission_ended.emit(m["title"], false)
	_cleanup()


func _cleanup() -> void:
	_clear_objective()
	if _race_marker_next:
		_race_marker_next.queue_free()
		_race_marker_next = null
	if _npc:
		_npc.queue_free()
		_npc = null
	# Mission vehicles stay in the world as ordinary vehicles; unspawned ones vanish.
	for id in _vehicles.keys():
		if _vehicles[id] is Dictionary:
			_vehicles.erase(id)
	_vehicles.clear()
	active = {}
	taxi_job = false
	_step = -1
	_time_limit = -1.0
	_abandon_time = 0.0
	_cooldown = 4.0
	hud.set_objective("")
	hud.set_timer(-1.0)
	_refresh_contacts()


# --- Taxi side job ------------------------------------------------------------------

func _start_taxi_job() -> void:
	taxi_job = true
	active = {"id": "taxi_job", "title": "Taxi", "steps": [], "contact": "youssef"}
	_refresh_contacts()
	hud.show_banner("TAXI", "Pick up fares. J to stop.")
	_queue_fare()


## Each fare: a pickup and a drop-off, generated on the fly.
func _queue_fare() -> void:
	_fare_crashes = 0
	active["steps"] = [
		{"type": "pickup", "loc": {"at": "near", "of": "player", "min": 80, "max": 220}, "text": "Pick up the fare"},
		{"type": "dropoff", "loc": {"at": "near", "of": "player", "min": 200, "max": 480}, "timed": true,
			"text": "Take the fare to the destination"},
	]
	_step = -1
	_next_step()


func _pay_fare() -> void:
	var dist: float = _step_data.get("_dist", 0.0)
	var base := 15.0 + _route_length_or(dist) * 0.12
	var tip := maxf(_time_limit, 0.0) * 0.8
	var factor := maxf(1.0 - 0.15 * _fare_crashes, 0.4)
	var total := int((base + tip) * factor)
	wallet.earn(total, "Taxi fare")
	var stats: Dictionary = SaveGame.load_data().get("stats", {})
	stats["fares"] = int(stats.get("fares", 0)) + 1
	SaveGame.store({"stats": stats})


func _route_length_or(fallback: float) -> float:
	var l := 0.0
	for i in _route.size() - 1:
		l += _route[i].distance_to(_route[i + 1])
	return maxf(l, fallback)


func _end_taxi_job(reason: String) -> void:
	hud.show_banner("TAXI", reason)
	_cleanup()


func _on_vehicle_entered(v: Vehicle) -> void:
	if active.is_empty() and v.display_name == "Petit Taxi":
		hud.set_hint("Press J for taxi fares")
		get_tree().create_timer(4.0).timeout.connect(func() -> void:
			if player.current_vehicle == v:
				hud.set_hint(""))
	var dmg := v.get_node_or_null("Damage") as VehicleDamage
	if dmg and not dmg.damaged.is_connected(_on_vehicle_damaged):
		dmg.damaged.connect(_on_vehicle_damaged)


func _on_vehicle_damaged(_c: float) -> void:
	if taxi_job and _passenger_aboard:
		_fare_crashes += 1
		hud.show_subtitle("Passenger: Aaa, b-chwiya! (Slow down!)", 2.0)


# --- Garage ------------------------------------------------------------------------

func _update_garage() -> void:
	if _garage_service == null:
		return
	var v := player.current_vehicle
	var inside := v != null and _garage_service.contains(v.global_position)
	if inside and not _garage_inside and v.get_speed_kmh() < 15.0:
		_use_garage(v)
	_garage_inside = inside


func _use_garage(v: Vehicle) -> void:
	var dmg := v.get_node_or_null("Damage") as VehicleDamage
	if wanted.stars > 0:
		if police.sees_player(wanted.current_sight_range()):
			hud.show_subtitle("Youssef: Not with the police watching, khoya! Lose them first.", 3.0)
		elif wallet.spend(RESPRAY_COST, "Respray"):
			wanted.clear()
			v.paint_color = Color.from_hsv(_rng.randf(), 0.5, 0.8)
			if v.paint_material:
				v.paint_material.albedo_color = v.paint_color
			if dmg:
				dmg.repair()
			hud.show_subtitle("Youssef: New colour, new car. Nobody saw anything!", 3.0)
		else:
			hud.show_subtitle("Youssef: A respray is %s, khoya." % Wallet.format(RESPRAY_COST), 3.0)
	elif dmg and dmg.condition < 99.0:
		if wallet.spend(REPAIR_COST, "Repair"):
			dmg.repair()
			hud.show_subtitle("Youssef: Safi, like new. Almost.", 3.0)
		else:
			hud.show_subtitle("Youssef: Repairs are %s. Come back with money." % Wallet.format(REPAIR_COST), 3.0)
	else:
		hud.show_subtitle("Youssef: Your car's fine. Go make some money!", 2.5)


# --- Places -------------------------------------------------------------------------

func _resolve(desc: Dictionary) -> Vector3:
	return _resolve_spot(desc)["pos"]


## A spot for `desc`: {pos: pavement point, kerb: kerbside point for vehicles
## and markers, yaw: facing along the road}.
func _resolve_spot(desc: Dictionary) -> Dictionary:
	match desc.get("at", "near"):
		"garage":
			return _road_spot(_v2(_points["garage"]), 0.0, 12.0)
		"point":
			return _road_spot(_v2(_points.get(desc["key"], player.global_position)), 0.0, 15.0)
		"area":
			for a in streamer.manifest.get("areas", []):
				if a["name"] == desc["name"]:
					var r: Array = a["rect"]
					return _road_spot(Vector2((r[0] + r[2]) * 0.5, (r[1] + r[3]) * 0.5), 0.0, 120.0)
			return _road_spot(_v2(player.global_position), 250.0, 500.0)
		"coast":
			return _road_spot(_coast_node_pos(), 0.0, 40.0)
		_:
			var of: String = desc.get("of", "player")
			var center: Vector3 = player.global_position if of == "player" else _points.get(of, player.global_position)
			return _road_spot(_v2(center), desc.get("min", 50.0), desc.get("max", 200.0))


## A road spot `min`..`max` metres from `center`, widening the search if the
## map is too small (the placeholder city is only ~500 m across).
func _road_spot(center: Vector2, rmin: float, rmax: float) -> Dictionary:
	var g := traffic.graph
	var spot := []
	for attempt in 4:
		spot = g.random_spot(center, rmin, rmax, _rng, false)
		if not spot.is_empty():
			break
		rmin *= 0.5
		rmax *= 1.5
	if spot.is_empty():
		var n := g.nearest_node(center)
		var p := g.nodes[n] if n >= 0 else center
		return {"pos": Vector3(p.x, 0.1, p.y), "kerb": Vector3(p.x, 0.1, p.y), "yaw": 0.0}
	var e: int = spot[0]
	var along: float = spot[2] if spot[1] == g.edge_a[e] else g.edge_length[e] - spot[2]
	var p := g.point_along(e, along)
	var q := g.point_along(e, minf(along + 1.0, g.edge_length[e]))
	var dir := (q - p).normalized() if q != p else Vector2(0, 1)
	var right := Vector2(-dir.y, dir.x)
	var w := g.edge_width[e]
	var pav := p + right * (w * 0.5 + 1.8)
	var kerb := p + right * maxf(w * 0.25, 1.5)
	return {"pos": Vector3(pav.x, 0.1, pav.y), "kerb": Vector3(kerb.x, 0.1, kerb.y), "yaw": atan2(dir.x, dir.y)}


func _coast_node_pos() -> Vector2:
	var g := traffic.graph
	var best := Vector2.ZERO
	var best_d := INF
	var step := maxi(1, g.nodes.size() / 3000)
	for i in range(0, g.nodes.size(), step):
		var p := g.nodes[i]
		var d := streamer.get_coast_distance(Vector3(p.x, 0, p.y))
		if d < best_d:
			best_d = d
			best = p
	return best


func _save_point(s: Dictionary, pos: Vector3) -> Vector3:
	if s.has("save_as"):
		_points[s["save_as"]] = pos
	return pos


# --- Objective markers, vehicles, GPS ----------------------------------------------------

func _set_objective(pos: Vector3, radius: float, kind: String) -> void:
	_clear_objective()
	_objective = MissionMarker.create(self, pos, kind, "", radius)
	_objective_pos = pos
	if _step_data.get("type") == "dropoff":
		_step_data["_dist"] = _v2(player.global_position).distance_to(_v2(pos))


func _clear_objective() -> void:
	if _objective:
		_objective.queue_free()
		_objective = null
	_objective_pos = Vector3.INF


## Mission vehicles are only created once the player is near (and the ground
## under them has streamed in).
func _spawn_pending_vehicles() -> void:
	for id in _vehicles.keys():
		var p = _vehicles[id]
		if not p is Dictionary:
			continue
		var pos: Vector3 = p["pos"]
		if player.global_position.distance_to(pos) > 150.0 or not streamer.is_loaded_at(pos):
			continue
		var v := (load(p["scene"]) as PackedScene).instantiate() as Vehicle
		v.spawned = true
		v.locked = p["locked"]
		add_child(v)
		v.global_transform = Transform3D(Basis(Vector3.UP, p["yaw"]), pos + Vector3.UP * 0.6)
		v.add_to_group("mission_vehicles")
		_vehicles[id] = v


## Recomputes the GPS route to the objective about once a second, along the
## roads (same flow field the police use).
func _update_route(delta: float) -> void:
	_route_timer -= delta
	if _route_timer > 0.0:
		return
	_route_timer = 1.0
	_route = PackedVector2Array()
	if _objective_pos == Vector3.INF:
		return
	var g := traffic.graph
	var target := g.nearest_node(_v2(_objective_pos))
	var start := g.nearest_node(_v2(player.global_position))
	if target < 0 or start < 0:
		return
	var field := g.flow_field(target, 8000)
	var next: Dictionary = field["next"]
	_route.append(_v2(player.global_position))
	var n := start
	for hop in 400:
		_route.append(g.nodes[n])
		if n == target or not next.has(n):
			break
		var e: int = next[n]
		var pts := g.edge_points[e]
		if g.edge_a[e] != n:
			pts = pts.duplicate()
			pts.reverse()
		for i in range(1, pts.size() - 1):
			_route.append(pts[i])
		n = g.other_end(e, n)
	_route.append(_v2(_objective_pos))


func _v2(p: Vector3) -> Vector2:
	return Vector2(p.x, p.z)
