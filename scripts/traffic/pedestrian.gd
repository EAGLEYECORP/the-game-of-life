class_name Pedestrian
extends Node3D
## A pedestrian walking the pavements of the road graph.
##
## No physics body at all, just a position that TrafficManager moves; reactions
## to the player are distance checks. That keeps a crowd of 60+ nearly free.
##
## State machine:
##   WALK        follow the pavement beside the road (or the middle of a footway)
##   IDLE        stop for a moment (phone, chat, window shopping)
##   SIDESTEP    the player on foot bumped into us: step aside
##   FLEE        a car is coming at us, or something scary happened: run away
##   KNOCKED     hit by the player's car: fall over...
##   GET_UP      ...and get back up, then flee

enum State { WALK, IDLE, SIDESTEP, FLEE, KNOCKED, GET_UP }

const PAVEMENT := 2.3          # Metres beyond the road edge.
const ANIM_DISTANCE := 60.0    # Limbs only animate closer than this.

var state := State.WALK
var walk_speed := 1.3

var _graph: RoadGraph
var _manager: TrafficManager
var _rng := RandomNumberGenerator.new()
var _edge := -1
var _from := -1
var _lane := PackedVector2Array()
var _seg := 0
var _seg_t := 0.0
var _pos := Vector2.ZERO
var _yaw := 0.0
var _side := 1.0                # Which pavement: +1 right of a->b, -1 left.
var _state_time := 0.0
var _state_len := 0.0
var _flee_dir := Vector2.ZERO
var _phase := 0.0               # Walk cycle.
var _fall := 0.0                # 0 standing, 1 lying down.
var _model: Node3D
var _limbs: Dictionary


func setup(manager: TrafficManager, graph: RoadGraph, spot: Array) -> void:
	_manager = manager
	_graph = graph
	_rng.randomize()
	walk_speed = _rng.randf_range(1.0, 1.6)
	_side = 1.0 if _rng.randf() < 0.5 else -1.0
	_model = Node3D.new()
	add_child(_model)
	_limbs = NpcVisuals.build_pedestrian(_model, _rng)
	_enter_edge(spot[0], spot[1])
	_advance(spot[2])
	_place()


func get_position_2d() -> Vector2:
	return _pos


func is_down() -> bool:
	return state == State.KNOCKED or state == State.GET_UP


## Every physics frame: move and animate.
func tick(delta: float, cam_dist: float) -> void:
	_state_time += delta
	var moving := 0.0
	match state:
		State.WALK:
			_advance(walk_speed * delta)
			moving = walk_speed
		State.IDLE:
			if _state_time > _state_len:
				_set_state(State.WALK)
		State.SIDESTEP, State.FLEE:
			var spd := 1.8 if state == State.SIDESTEP else 5.5
			_pos += _flee_dir * spd * delta
			_yaw = lerp_angle(_yaw, atan2(_flee_dir.x, _flee_dir.y), clampf(10.0 * delta, 0.0, 1.0))
			moving = spd
			if _state_time > _state_len:
				_rejoin_pavement()
		State.KNOCKED:
			_fall = minf(_fall + delta * 4.0, 1.0)
			_pos += _flee_dir * maxf(3.0 - _state_time * 6.0, 0.0) * delta   # Slide a bit.
			if _state_time > 3.0:
				_set_state(State.GET_UP)
		State.GET_UP:
			_fall = maxf(_fall - delta * 1.5, 0.0)
			if _fall <= 0.0:
				_start_flee(_flee_dir, 3.0)
	_place()
	if cam_dist < ANIM_DISTANCE:
		_animate(delta, moving)


## Reactions to the player, ~10 Hz. `player_pos`: player on foot (or INF when
## driving); `car_pos/car_vel`: the player's vehicle (or INF / zero).
func think(player_pos: Vector2, car_pos: Vector2, car_vel: Vector2) -> void:
	if is_down():
		return
	# A car is coming straight for us: get out of the way.
	if car_pos != Vector2.INF:
		var to_me := _pos - car_pos
		var dist := to_me.length()
		var spd := car_vel.length()
		if dist < 1.6 and spd > 3.0:
			_knock_down(car_vel.normalized())
			return
		if spd > 4.0 and dist < 4.0 + spd * 1.2:
			var heading := car_vel / spd
			var ahead := to_me.dot(heading)
			var lateral := to_me.dot(Vector2(-heading.y, heading.x))
			if ahead > 0.0 and absf(lateral) < 3.0 and state != State.FLEE:
				# Dive to whichever side of the car's path we're already on.
				var away := Vector2(-heading.y, heading.x) * (1.0 if lateral >= 0.0 else -1.0)
				_start_flee((away * 2.0 + heading * 0.3).normalized(), 2.0)
				return
	# Player walking into us: step aside.
	if player_pos != Vector2.INF and state == State.WALK:
		var d := _pos - player_pos
		if d.length() < 1.0:
			_flee_dir = d.normalized() if d.length() > 0.01 else Vector2.RIGHT
			_set_state(State.SIDESTEP)
			_state_len = 0.6


## Something scary nearby (a crash, someone knocked over): run.
func scare(from: Vector2) -> void:
	if is_down() or state == State.FLEE:
		return
	var away := (_pos - from).normalized()
	_start_flee(away if away != Vector2.ZERO else Vector2.RIGHT, 3.5)


# --- Internals ----------------------------------------------------------------

func _set_state(s: State) -> void:
	state = s
	_state_time = 0.0


func _start_flee(dir: Vector2, seconds: float) -> void:
	_flee_dir = dir
	_set_state(State.FLEE)
	_state_len = seconds


func _knock_down(push: Vector2) -> void:
	_flee_dir = push
	_set_state(State.KNOCKED)
	_manager.scare_pedestrians(_pos, 15.0)


## After running off, walk back onto the nearest pavement of the current road.
func _rejoin_pavement() -> void:
	_enter_edge(_edge, _from)
	_set_state(State.WALK)


func _lane_for(e: int, from_node: int, side: float) -> PackedVector2Array:
	var off := 0.0
	if _graph.edge_kind[e] != RoadGraph.Kind.WALK_ONLY:
		off = (_graph.edge_width[e] * 0.5 + PAVEMENT) * side
	else:
		off = 0.4 * side     # Keep right-ish on footways so people pass.
	# Side is relative to a->b; flip when walking the other way.
	if from_node != _graph.edge_a[e]:
		off = -off
	return _graph.lane(e, from_node, off, 0.0)


func _enter_edge(e: int, from_node: int) -> void:
	_edge = e
	_from = from_node
	# Pick the pavement closest to where we are, so we don't teleport across.
	var lane := _lane_for(e, from_node, _side)
	if _lane.size() > 0:
		var other := _lane_for(e, from_node, -_side)
		if _closest_index(other) >= 0 and _dist_to(other) < _dist_to(lane):
			lane = other
			_side = -_side
	_lane = lane
	_seg = 0
	_seg_t = 0.0
	if _state_time > 0.0 or _pos != Vector2.ZERO:
		# Start from the closest point on the new lane.
		var i := _closest_index(_lane)
		_seg = clampi(i, 0, _lane.size() - 2)
		_lane.insert(_seg, _pos)


func _advance(dist: float) -> void:
	while dist > 0.0:
		var seg_len := _lane[_seg].distance_to(_lane[_seg + 1])
		if _seg_t + dist < seg_len:
			_seg_t += dist
			break
		dist -= seg_len - _seg_t
		_seg += 1
		_seg_t = 0.0
		if _seg >= _lane.size() - 1:
			var node := _graph.other_end(_edge, _from)
			_pos = _lane[-1]
			var next := _graph.pick_next(_edge, node, _rng, true)
			_enter_edge(next, node)
			if _rng.randf() < 0.15:
				_set_state(State.IDLE)
				_state_len = _rng.randf_range(2.0, 6.0)
				return
	var a := _lane[_seg]
	var b := _lane[_seg + 1]
	_pos = a.move_toward(b, _seg_t)
	if (b - a).length_squared() > 0.0001:
		_yaw = lerp_angle(_yaw, atan2(b.x - a.x, b.y - a.y), 0.2)


func _place() -> void:
	position = Vector3(_pos.x, 0.0, _pos.y)
	rotation.y = _yaw
	# Falling over backwards around the feet.
	_model.rotation.x = -_fall * PI * 0.5
	_model.position.y = _fall * 0.15


func _animate(delta: float, moving: float) -> void:
	if moving > 0.1:
		_phase += delta * moving * 4.5
	else:
		_phase = lerpf(_phase, roundf(_phase / PI) * PI, clampf(delta * 8.0, 0.0, 1.0))
	var swing := sin(_phase) * clampf(moving * 0.35, 0.0, 0.8)
	_limbs["legs"][0].rotation.x = swing
	_limbs["legs"][1].rotation.x = -swing
	_limbs["arms"][0].rotation.x = -swing * 0.8
	_limbs["arms"][1].rotation.x = swing * 0.8


func _closest_index(pts: PackedVector2Array) -> int:
	var best := -1
	var best_d := INF
	for i in pts.size():
		var d := pts[i].distance_squared_to(_pos)
		if d < best_d:
			best_d = d
			best = i
	return best


func _dist_to(pts: PackedVector2Array) -> float:
	var i := _closest_index(pts)
	return INF if i < 0 else pts[i].distance_to(_pos)
