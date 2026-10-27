class_name TrafficCar
extends AnimatableBody3D
## An AI car driving along the road graph.
##
## Deliberately cheap: no wheel physics. It slides along its lane polyline as
## a kinematic body (so the player still bumps into it and gets pushed), with
## one baked mesh. TrafficManager calls tick() every physics frame and think()
## ten times a second, staggered across cars.
##
## State machine:
##   DRIVE      cruise at the road's speed, slow for turns and cars ahead
##   WAIT_LIGHT stopped at a red light, waiting for green
##   BLOCKED    something (often the player) is in the way; honks if it lasts
##   PANIC      the player rammed us: honk, then floor it and ignore lights
## Every state uses the same rule for speed: "the fastest speed from which I can
## still stop before the obstacle/stop line", so stopping is always smooth.

enum State { DRIVE, WAIT_LIGHT, BLOCKED, PANIC }

const ACCEL := 3.0          # m/s^2
const BRAKE := 6.5          # m/s^2
const LOOK_AHEAD := 22.0    # m checked in front for obstacles
const PANIC_TIME := 6.0
const HONK_AFTER := 1.5     # s blocked by the player before honking

var state := State.DRIVE
var display_name := "Car"
var template: Dictionary
var paint := Color.WHITE
var length := 4.0
var half_width := 0.9
var speed := 0.0

var _graph: RoadGraph
var _manager: TrafficManager
var _rng := RandomNumberGenerator.new()
var _edge := -1
var _from := -1                 # Node we left; heading to the other end.
var _lane := PackedVector2Array()
var _seg := 0                   # Current segment index in _lane.
var _seg_t := 0.0               # Metres along the current segment.
var _remaining := 0.0           # Metres left on this lane.
var _next_edge := -1
var _yaw := 0.0
var _ride := 0.5
var _personality := 1.0         # Some drivers are faster than others.
var _target_speed := 0.0
var _state_time := 0.0
var _honk_cooldown := 0.0
var _player_block_time := 0.0   # How long the player has been in our way.
var _last_think := 0.0
var _horn: AudioStreamPlayer3D


func setup(manager: TrafficManager, graph: RoadGraph, tpl: Dictionary, color: Color, spot: Array) -> void:
	_manager = manager
	_graph = graph
	template = tpl
	paint = color
	display_name = tpl["name"]
	length = tpl["length"]
	half_width = tpl["width"] * 0.5
	_ride = tpl["ride_height"]
	_rng.randomize()
	_personality = _rng.randf_range(0.85, 1.15) * (0.75 if tpl["two_wheeler"] else 1.0)
	add_to_group("traffic_cars")
	collision_layer = 4       # Same layer as vehicles: the player collides with us.
	collision_mask = 0

	var mi := MeshInstance3D.new()
	mi.mesh = tpl["mesh"]
	add_child(mi)
	for l in tpl["labels"]:
		var label: Label3D = l[0].duplicate()
		label.transform = l[1]
		add_child(label)
	var cs := CollisionShape3D.new()
	cs.shape = tpl["shape"]
	cs.transform = tpl["shape_xform"]
	add_child(cs)

	_enter_edge(spot[0], spot[1], spot[2])
	speed = _graph.speed_limit(_edge) * 0.6
	_place(true)


## Movement: every physics frame for every car, so it is kept minimal.
func tick(delta: float) -> void:
	_state_time += delta
	_honk_cooldown -= delta
	var rate := ACCEL if _target_speed > speed else BRAKE
	speed = move_toward(speed, _target_speed, rate * delta)
	_advance(speed * delta)
	_place(false)


## Decisions: obstacles, lights, state changes. ~10 Hz.
func think(t: float) -> void:
	var dt := clampf(t - _last_think, 0.0, 0.5)
	_last_think = t
	var limit := _graph.speed_limit(_edge) * _personality
	# Slow down for the corner at the end of this road.
	if _next_edge >= 0 and _next_edge != _edge:
		limit = minf(limit, sqrt(36.0 + 2.0 * 3.0 * _remaining))
	elif _next_edge == _edge:
		limit = minf(limit, sqrt(4.0 + 2.0 * 3.0 * _remaining))   # U-turn.

	if state == State.PANIC:
		limit *= 1.5
		if _state_time > PANIC_TIME:
			_set_state(State.DRIVE)

	# Traffic light at the end of this road?
	var stop_for_light := false
	if state != State.PANIC:
		var light := _graph.light_at(_graph.other_end(_edge, _from), _edge, t)
		if light == RoadGraph.Light.RED or (light == RoadGraph.Light.YELLOW and _remaining > speed * 1.5):
			stop_for_light = _remaining > 0.5
			limit = minf(limit, _stop_speed(_remaining - 1.0))

	# Anything in front of us?
	var hit := _manager.obstacle_ahead(self, _pos2(), _dir2(), LOOK_AHEAD, half_width + 0.6)
	var blocked_by_player := false
	if not hit.is_empty():
		var gap: float = hit[0] - length * 0.5 - hit[1] - 1.5
		limit = minf(limit, _stop_speed(gap))
		blocked_by_player = hit[2] and gap < 4.0

	_target_speed = maxf(limit, 0.0)

	match state:
		State.DRIVE, State.WAIT_LIGHT, State.BLOCKED:
			if stop_for_light and speed < 0.5:
				if state != State.WAIT_LIGHT:
					_set_state(State.WAIT_LIGHT)
			elif not hit.is_empty() and speed < 0.5 and _target_speed < 0.5:
				if state != State.BLOCKED:
					_set_state(State.BLOCKED)
			elif state != State.DRIVE and _target_speed > 1.0:
				_set_state(State.DRIVE)

	# Someone standing or parked in front of us, whatever else is going on:
	# lean on the horn after a moment. Very Casablanca.
	_player_block_time = _player_block_time + dt if blocked_by_player and speed < 1.0 else 0.0
	if _player_block_time > HONK_AFTER:
		honk(0.6)

	if state == State.BLOCKED:
		# Two AI cars stuck nose to nose at a junction: after a while, the one
		# that has waited longest edges through anyway.
		if not blocked_by_player and _state_time > 4.0 + _personality * 2.0:
			_target_speed = 2.0


## Called by the manager when the player's vehicle hits us hard.
func on_rammed() -> void:
	if state != State.PANIC:
		_set_state(State.PANIC)
		honk(1.2)


func honk(duration: float) -> void:
	if _honk_cooldown > 0.0:
		return
	_honk_cooldown = duration + 1.5
	if _horn == null:
		_horn = AudioStreamPlayer3D.new()
		_horn.stream = SoundSynth.horn(template["horn"])
		_horn.unit_size = 6.0
		_horn.max_distance = 120.0
		add_child(_horn)
	_horn.play()
	get_tree().create_timer(duration).timeout.connect(_horn.stop)


## Current velocity on the ground plane (m/s).
func velocity_2d() -> Vector2:
	return _dir2() * speed


## For the player: same door API as Vehicle so the "Press F" hint works.
func get_door_position() -> Vector3:
	return global_transform * Vector3(half_width + 0.7, -0.3, 0.0)


func has_driver() -> bool:
	return false


## Player carjacks us: swap for a real drivable Vehicle, eject the driver.
func hijack() -> Vehicle:
	return _manager.convert_to_vehicle(self)


# --- Movement internals -------------------------------------------------------

func _set_state(s: State) -> void:
	state = s
	_state_time = 0.0


## Distance at which we can still stop, as a speed.
func _stop_speed(dist: float) -> float:
	return sqrt(2.0 * BRAKE * 0.6 * maxf(dist, 0.0))


func _enter_edge(e: int, from_node: int, along: float) -> void:
	var start := _pos2() if not _lane.is_empty() else Vector2.INF
	_edge = e
	_from = from_node
	var offset := 0.0
	var w := _graph.edge_width[e]
	if _graph.edge_oneway[e] == 0 or w >= 7.0:
		offset = maxf(w * 0.25, 1.3)
	_lane = _graph.lane(e, from_node, offset, 3.0)
	if start != Vector2.INF:
		# Join smoothly from where we are now (cuts across the junction).
		_lane.insert(0, start)
	_seg = 0
	_seg_t = 0.0
	_remaining = 0.0
	for i in _lane.size() - 1:
		_remaining += _lane[i].distance_to(_lane[i + 1])
	_next_edge = _graph.pick_next(e, _graph.other_end(e, from_node), _rng, false)
	if along > 0.0:
		_advance(along)


func _advance(dist: float) -> void:
	_remaining -= dist
	while dist > 0.0:
		var seg_len := _lane[_seg].distance_to(_lane[_seg + 1])
		if _seg_t + dist < seg_len:
			_seg_t += dist
			return
		dist -= seg_len - _seg_t
		_seg += 1
		_seg_t = 0.0
		if _seg >= _lane.size() - 1:
			# End of this road: on to the next one.
			if _next_edge < 0:
				_manager.request_despawn(self)
				_seg = _lane.size() - 2
				_seg_t = _lane[_seg].distance_to(_lane[_seg + 1])
				return
			var node := _graph.other_end(_edge, _from)
			_seg = _lane.size() - 2
			_seg_t = _lane[_seg].distance_to(_lane[_seg + 1])
			_enter_edge(_next_edge, node, 0.0)


func _pos2() -> Vector2:
	if _lane.is_empty():
		return Vector2.ZERO
	var a := _lane[_seg]
	var b := _lane[mini(_seg + 1, _lane.size() - 1)]
	return a.move_toward(b, _seg_t)


func _dir2() -> Vector2:
	return Vector2(sin(_yaw), cos(_yaw))


func _place(snap: bool) -> void:
	var p := _pos2()
	var a := _lane[_seg]
	var b := _lane[mini(_seg + 1, _lane.size() - 1)]
	var d := (b - a)
	if d.length_squared() > 0.0001:
		var target := atan2(d.x, d.y)
		_yaw = target if snap else lerp_angle(_yaw, target, clampf(speed * 0.5 * get_physics_process_delta_time(), 0.0, 1.0))
	global_transform = Transform3D(Basis(Vector3.UP, _yaw), Vector3(p.x, 0.06 + _ride, p.y))
