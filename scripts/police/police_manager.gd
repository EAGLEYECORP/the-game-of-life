class_name PoliceManager
extends Node3D
## Dispatches and drives the police according to the wanted level.
##
## Police cars are real physics vehicles (they can ram you and you can ram
## them) driven by this manager through Vehicle's ai_* inputs. They find the
## player along the real roads with one shared flow field (Dijkstra outward
## from the player's junction, refreshed every second): each unit just follows
## the "next road" pointer of the junction it's heading to. Up close they leave
## the road network and go straight for you.
##
## Per-unit state machine:
##   RESPOND   follow the roads toward the player, siren on
##   PURSUE    close enough: drive straight at the player's predicted position
##   RAM       5 stars: pursue at full speed and hit the player on purpose
##   ARREST    player on foot: pull up next to them
##   REVERSE   stuck against something: back up and turn
##   LEAVE     wanted level gone: siren off, drive off, then despawn
## Standing still next to police while wanted gets you busted.

signal busted

enum State { RESPOND, PURSUE, RAM, ARREST, REVERSE, LEAVE }

@export var player: Player
@export var traffic: TrafficManager
@export var wanted: WantedSystem
@export var police_scene: PackedScene
## Police cars on duty for 0..5 stars.
@export var units_per_star: PackedInt32Array = [0, 2, 3, 4, 5, 7]
@export var spawn_min := 110.0
@export var spawn_max := 220.0
@export var despawn_distance := 420.0
## Seconds next to a cop, nearly stationary, before you're busted.
@export var bust_time := 3.0

const FIELD_REFRESH := 1.0
const FIELD_MAX_NODES := 6000

## Per-car bookkeeping.
class Unit:
	var vehicle: Vehicle
	var state := State.RESPOND
	var node := -1                          # Junction we're driving to.
	var waypoints := PackedVector2Array()   # Road polyline to that junction.
	var stuck_time := 0.0
	var reverse_time := 0.0
	var reverse_steer := 0.0
	var leave_time := 0.0

var units: Array[Unit] = []
## 0..1, how close the player is to being busted (for the HUD).
var bust_progress := 0.0

var _field := {}
var _field_node := -1
var _field_timer := 0.0
var _spawn_timer := 0.0
var _sight_timer := 0.0
var _sees_player := false
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	if wanted:
		wanted.police = self
		wanted.stars_changed.connect(_on_stars_changed)


func _physics_process(delta: float) -> void:
	if traffic == null or traffic.graph == null or player == null:
		return
	var graph := traffic.graph
	var stars := wanted.stars if wanted else 0
	var ppos := _player_pos()

	# Shared route to the player, refreshed every second.
	_field_timer -= delta
	if stars > 0 and _field_timer <= 0.0:
		_field_timer = FIELD_REFRESH
		var n := graph.nearest_node(ppos)
		if n >= 0:
			_field = graph.flow_field(n, FIELD_MAX_NODES)
			_field_node = n

	# Dispatch more units if the wanted level calls for them.
	var wanted_units := units_per_star[clampi(stars, 0, units_per_star.size() - 1)]
	var active := units.filter(func(u: Unit) -> bool: return u.state != State.LEAVE).size()
	_spawn_timer -= delta
	if active < wanted_units and _spawn_timer <= 0.0:
		# The first unit comes quicker, from closer.
		_spawn_timer = 2.5 if active > 0 else 0.5
		_spawn_unit(graph, ppos, active == 0)
	elif active > wanted_units:
		# Too many for this level: the furthest ones head off.
		var far := _furthest_active(ppos)
		if far:
			_set_state(far, State.LEAVE)

	for i in range(units.size() - 1, -1, -1):
		var u := units[i]
		if not is_instance_valid(u.vehicle):
			units.remove_at(i)
			continue
		var d := _pos2(u.vehicle).distance_to(ppos)
		if d > despawn_distance or (u.state == State.LEAVE and (d > 140.0 or u.leave_time > 25.0)):
			u.vehicle.queue_free()
			units.remove_at(i)
			continue
		_drive(u, graph, ppos, stars, delta)

	_check_bust(ppos, stars, delta)


# --- Queries --------------------------------------------------------------------

## True if any officer within `range_m` has a clear line of sight to `pos`.
func can_see(pos: Vector3, range_m: float) -> bool:
	var space := get_world_3d().direct_space_state
	for u in units:
		if not is_instance_valid(u.vehicle) or u.state == State.LEAVE:
			continue
		var from := u.vehicle.global_position + Vector3.UP * 1.2
		if from.distance_to(pos) > range_m:
			continue
		var q := PhysicsRayQueryParameters3D.create(from, pos + Vector3.UP * 1.2, 1)
		if space.intersect_ray(q).is_empty():
			return true
	return false


## Cached sight check on the player, refreshed twice a second.
func sees_player(range_m: float) -> bool:
	_sight_timer -= get_physics_process_delta_time()
	if _sight_timer <= 0.0:
		_sight_timer = 0.5
		_sees_player = can_see(player.global_position, range_m)
	return _sees_player


## Positions of police cars, for the minimap.
func unit_positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	for u in units:
		if is_instance_valid(u.vehicle):
			out.append(u.vehicle.global_position)
	return out


# --- Spawning -----------------------------------------------------------------------

func _spawn_unit(graph: RoadGraph, ppos: Vector2, first: bool) -> void:
	var rmin := 70.0 if first else spawn_min
	var rmax := 150.0 if first else spawn_max
	for attempt in 6:
		var spot := graph.random_spot(ppos, rmin, rmax, _rng, false)
		if spot.is_empty():
			continue
		var e: int = spot[0]
		var from: int = spot[1]
		var along: float = spot[2] if from == graph.edge_a[e] else graph.edge_length[e] - spot[2]
		var p := graph.point_along(e, along)
		# Face along the road, toward the player's side of it.
		var dir := graph.point_along(e, minf(along + 3.0, graph.edge_length[e])) - graph.point_along(e, maxf(along - 3.0, 0.0))
		if dir.dot(ppos - p) < 0.0:
			dir = -dir
		var v := police_scene.instantiate() as Vehicle
		v.ai_controlled = true
		v.siren_on = true
		v.spawned = true
		v.add_to_group("police")
		add_child(v)
		v.global_transform = Transform3D(Basis(Vector3.UP, atan2(dir.x, dir.y)), Vector3(p.x, 0.75, p.y))
		var u := Unit.new()
		u.vehicle = v
		u.node = graph.edge_b[e] if dir.dot(graph.nodes[graph.edge_b[e]] - p) > 0.0 else graph.edge_a[e]
		units.append(u)
		return


func _furthest_active(ppos: Vector2) -> Unit:
	var best: Unit = null
	var best_d := -1.0
	for u in units:
		if u.state == State.LEAVE or not is_instance_valid(u.vehicle):
			continue
		var d := _pos2(u.vehicle).distance_to(ppos)
		if d > best_d:
			best_d = d
			best = u
	return best


func _on_stars_changed(stars: int) -> void:
	if stars == 0:
		for u in units:
			_set_state(u, State.LEAVE)


# --- Driving ------------------------------------------------------------------------

func _drive(u: Unit, graph: RoadGraph, ppos: Vector2, stars: int, delta: float) -> void:
	var v := u.vehicle
	var pos := _pos2(v)
	var dist := pos.distance_to(ppos)
	var on_foot := player.current_vehicle == null
	var aggressive := stars >= 5
	var direct_range := 90.0 if aggressive else 55.0

	# Pick the state (REVERSE and LEAVE run until they finish).
	if u.state == State.REVERSE:
		u.reverse_time -= delta
		v.ai_throttle = 0.0
		v.ai_reverse = 1.0
		v.ai_steer = u.reverse_steer
		v.ai_handbrake = false
		if u.reverse_time <= 0.0:
			_set_state(u, State.RESPOND)
		return
	if u.state == State.LEAVE:
		u.leave_time += delta
		v.siren_on = false
	elif dist < direct_range:
		if on_foot:
			_set_state(u, State.ARREST)
		else:
			_set_state(u, State.RAM if aggressive else State.PURSUE)
	elif u.state != State.RESPOND:
		_set_state(u, State.RESPOND)
		u.waypoints.clear()
		u.node = graph.nearest_node(pos)

	# Where to aim.
	var target := ppos
	var cruise := 15.0 + 2.5 * stars
	match u.state:
		State.RESPOND:
			target = _road_target(u, graph, pos, ppos)
		State.PURSUE, State.RAM:
			# Lead the target: aim where the player will be.
			var lead := 0.35 if u.state == State.RAM else 0.6
			target = ppos + _player_vel() * lead * clampf(dist / 20.0, 0.3, 1.5)
			cruise = 32.0 if aggressive else 24.0
		State.ARREST:
			target = ppos
		State.LEAVE:
			target = pos + _dir2(v) * 40.0
			cruise = 9.0

	var local := v.global_transform.affine_inverse() * Vector3(target.x, v.global_position.y, target.y)
	var angle := atan2(local.x, local.z)          # >0 = target on our left.
	var speed := v.get_forward_speed()
	var desired := cruise * clampf(1.25 - absf(angle) * 0.8, 0.3, 1.0)

	if u.state == State.PURSUE and dist < 12.0:
		# Shadow the player rather than wrecking both cars...
		desired = minf(desired, _player_vel().length() + 3.0)
	elif u.state == State.ARREST:
		# ...or pull up beside them on foot.
		desired = clampf((dist - 5.0) * 1.2, 0.0, 12.0)

	v.ai_steer = clampf(angle * 1.8, -1.0, 1.0)
	v.ai_throttle = 1.0 if speed < desired else 0.0
	v.ai_reverse = 1.0 if speed > desired + 3.0 else 0.0
	# Aggressive units yank the handbrake to swing round corners.
	v.ai_handbrake = aggressive and absf(angle) > 0.9 and speed > 14.0

	# Target behind us and close: a quick three-point turn.
	if absf(angle) > 2.2 and pos.distance_to(target) < 25.0 and absf(speed) < 6.0 and u.state != State.ARREST:
		_start_reverse(u, -signf(angle))
		return
	# Pushing but going nowhere: back off and try another line.
	if v.ai_throttle > 0.5 and absf(speed) < 1.0:
		u.stuck_time += delta
		if u.stuck_time > 1.5:
			_start_reverse(u, -signf(v.ai_steer) if v.ai_steer != 0.0 else 1.0)
	else:
		u.stuck_time = 0.0


## Next point along the roads toward the player, from the shared flow field.
func _road_target(u: Unit, graph: RoadGraph, pos: Vector2, ppos: Vector2) -> Vector2:
	while not u.waypoints.is_empty() and pos.distance_to(u.waypoints[0]) < 8.0:
		u.waypoints.remove_at(0)
	if u.waypoints.is_empty():
		if u.node < 0:
			u.node = graph.nearest_node(pos)
		var next: Dictionary = _field.get("next", {})
		if u.node < 0 or u.node == _field_node or not next.has(u.node):
			return ppos   # At the player's junction (or off the field): go direct.
		if pos.distance_to(graph.nodes[u.node]) > 10.0 and u.waypoints.is_empty():
			u.waypoints.append(graph.nodes[u.node])
			return u.waypoints[0]
		# Arrived at a junction: queue the road that leads closer to the player.
		var e: int = next[u.node]
		var pts := graph.edge_points[e]
		if graph.edge_a[e] != u.node:
			pts = pts.duplicate()
			pts.reverse()
		for i in range(1, pts.size()):
			u.waypoints.append(pts[i])
		u.node = graph.other_end(e, u.node)
	return u.waypoints[0]


func _start_reverse(u: Unit, steer: float) -> void:
	_set_state(u, State.REVERSE)
	u.reverse_time = 1.3
	u.reverse_steer = steer
	u.stuck_time = 0.0


func _set_state(u: Unit, s: State) -> void:
	if u.state == s:
		return
	u.state = s
	if s == State.LEAVE:
		u.leave_time = 0.0
		u.vehicle.siren_on = false


## Busted: wanted, (nearly) stopped, with an officer right next to you.
func _check_bust(ppos: Vector2, stars: int, delta: float) -> void:
	if stars == 0:
		bust_progress = 0.0
		return
	var slow := _player_vel().length() < 1.5
	var cop_near := false
	for u in units:
		if is_instance_valid(u.vehicle) and u.state != State.LEAVE \
				and _pos2(u.vehicle).distance_to(ppos) < 7.0 and u.vehicle.linear_velocity.length() < 3.0:
			cop_near = true
			break
	if slow and cop_near:
		bust_progress += delta / bust_time
		if bust_progress >= 1.0:
			bust_progress = 0.0
			busted.emit()
	else:
		bust_progress = maxf(bust_progress - delta / bust_time, 0.0)


# --- Helpers --------------------------------------------------------------------------

func _player_pos() -> Vector2:
	return Vector2(player.global_position.x, player.global_position.z)


func _player_vel() -> Vector2:
	var v := player.current_vehicle.linear_velocity if player.current_vehicle else player.velocity
	return Vector2(v.x, v.z)


func _pos2(n: Node3D) -> Vector2:
	return Vector2(n.global_position.x, n.global_position.z)


func _dir2(n: Node3D) -> Vector2:
	var z := n.global_basis.z
	return Vector2(z.x, z.z).normalized()
