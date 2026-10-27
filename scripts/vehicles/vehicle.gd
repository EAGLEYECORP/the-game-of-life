class_name Vehicle
extends VehicleBody3D
## Drivable vehicle: cars, taxis and scooters all use this script.
##
## Built on Godot's VehicleBody3D (raycast wheels), with arcade helpers on top so
## it feels fun rather than like a simulator:
##   - punchy engine that fades out toward top speed,
##   - grip assist that kills most sideways sliding (the handbrake relaxes it
##     for drifts),
##   - downforce at speed, and an "upright" torque that resists rolling over,
##   - automatic flip-back if you end up on the roof,
##   - two-wheelers (scooters) ride on 4 narrow hidden wheels and lean visually.
##
## Lights, sound and damage live in child component nodes (VehicleLights,
## VehicleSounds, VehicleDamage) that read this script's state.
##
## Scene conventions (see scenes/vehicles/*.tscn):
##   Body/Paint*   meshes that get this vehicle's paint colour
##   Body/Rider    optional rider mesh, shown while driven (scooters)
##   Seat, DoorExit  markers for the driver position and the exit spot
## Local axes: +Z is the front, +X the driver's (left) side.

## Emitted when someone gets in (driver) or out (null).
signal driver_changed(driver: Player)

@export var display_name := "Car"

@export_group("Paint")
## Colours picked from at random when the vehicle spawns.
@export var paint_options: PackedColorArray = [Color(0.9, 0.9, 0.88)]
@export var randomize_paint := true
## Used when randomize_paint is off.
@export var paint_color := Color(0.9, 0.9, 0.88)

@export_group("Engine")
@export var max_engine_force := 3000.0   ## Push per driven wheel at 0 km/h (N).
@export var top_speed_force_ratio := 0.35 ## Fraction of that force left at top speed.
@export var max_reverse_force := 1500.0
@export var max_brake := 50.0            ## Scale with mass (about mass / 24).
@export var max_speed_kmh := 160.0
@export var max_reverse_kmh := 30.0
@export var throttle_response := 4.0     ## How fast keyboard throttle ramps (1/s).

@export_group("Steering")
@export var max_steer_angle := 0.6       ## Radians at low speed.
@export var high_speed_steer_angle := 0.15
@export var steer_speed := 3.5           ## Wheel turn rate (rad/s).

@export_group("Arcade handling")
## Share of sideways velocity removed per second while grounded.
@export var grip_assist := 3.0
## Rear-wheel friction multiplier while the handbrake is held (lower = more drift).
@export var handbrake_grip := 0.45
## Extra force (N per (m/s)^2) pressing the vehicle onto the road at speed.
@export var downforce := 4.0
## How hard the vehicle tries to stay upright (per kg). Scooters need a lot.
@export var upright_strength := 6.0
@export var upright_damping := 2.0
## Air resistance; slows the vehicle gently when coasting.
@export var drag := 0.4

@export_group("Two-wheeler")
@export var two_wheeler := false
@export var lean_angle := 0.45           ## Max visual lean (radians).
## Show the rider mesh ($Body/Rider) while driven. Cars hide the player instead.
@export var shows_rider := false

@export_group("Camera")
@export var camera_distance := 7.5
@export var camera_height := 1.6
@export var camera_fov := 72.0

@export_group("Police")
## Police vehicle: siren and light bar, crimes against it count double.
@export var is_police := false

## The player currently driving, or null.
var driver: Player = null

## AI driving (police): set ai_controlled and write the ai_* inputs each frame
## instead of the keyboard. An AI-driven vehicle counts as occupied.
var ai_controlled := false
var ai_throttle := 0.0       ## 0..1
var ai_reverse := 0.0        ## 0..1
var ai_steer := 0.0          ## -1..1, positive = left
var ai_handbrake := false
var siren_on := false
## Locked parked cars must be broken into (takes a moment, sets off the alarm).
var locked := false
## Spawned by VehicleSpawner (as opposed to placed in the level).
var spawned := false
## This vehicle's own paint material (VehicleDamage dirties it).
var paint_material: StandardMaterial3D

# Control state, read by the light/sound components.
var throttle := 0.0      ## 0..1 after smoothing.
var is_braking := false
var horn_pressed := false
var lights_on := false

var _rear_wheels: Array[VehicleWheel3D] = []
var _base_rear_grip := 1.0
var _handbrake := false
var _upside_down_time := 0.0
var _alarm_time := 0.0

@onready var _seat: Marker3D = $Seat
@onready var _door: Marker3D = $DoorExit
@onready var _body: Node3D = $Body
@onready var _rider: Node3D = get_node_or_null("Body/Rider")


func _ready() -> void:
	add_to_group("vehicles")
	brake = max_brake
	for child in get_children():
		if child is VehicleWheel3D and child.position.z < 0.0:
			_rear_wheels.append(child)
	if not _rear_wheels.is_empty():
		_base_rear_grip = _rear_wheels[0].wheel_friction_slip
	if _rider:
		_rider.visible = false
	if randomize_paint and not paint_options.is_empty():
		paint_color = paint_options[randi() % paint_options.size()]
	_apply_paint()


func _physics_process(delta: float) -> void:
	if driver or ai_controlled:
		_read_controls(delta)
	if driver:
		# Keep the hidden player glued to the seat so anything that asks "where
		# is the player?" (map streaming, HUD) gets a sensible answer.
		driver.global_position = _seat.global_position
	elif not ai_controlled:
		throttle = 0.0
		engine_force = 0.0
		steering = move_toward(steering, 0.0, steer_speed * delta)
		brake = max_brake
		is_braking = false
		horn_pressed = false
		_handbrake = false

	_apply_arcade_forces(delta)
	if two_wheeler:
		_update_lean(delta)
	_alarm_time = maxf(_alarm_time - delta, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if driver == null:
		return
	if event.is_action_pressed("interact"):
		get_viewport().set_input_as_handled()
		driver.exit_vehicle()
	elif event.is_action_pressed("toggle_lights"):
		get_viewport().set_input_as_handled()
		lights_on = not lights_on


# --- Driving ------------------------------------------------------------------

func _read_controls(delta: float) -> void:
	var want_throttle := ai_throttle
	var reverse := ai_reverse
	var steer_input := ai_steer
	_handbrake = ai_handbrake
	if driver:
		want_throttle = Input.get_action_strength("move_forward")
		reverse = Input.get_action_strength("move_back")
		steer_input = Input.get_axis("move_right", "move_left") # Left = positive.
		_handbrake = Input.is_action_pressed("handbrake")
		horn_pressed = Input.is_action_pressed("horn")

	# Ramp keyboard throttle so tapping W doesn't spin the wheels.
	throttle = move_toward(throttle, want_throttle, throttle_response * delta)

	var forward_speed := get_forward_speed()
	var speed_kmh := absf(forward_speed) * 3.6
	var force := 0.0
	var brake_force := 0.0

	if reverse > 0.0:
		if forward_speed > 1.0:
			brake_force = max_brake * reverse        # Rolling forwards: brake first.
		elif speed_kmh < max_reverse_kmh:
			force = -max_reverse_force * reverse
	elif throttle > 0.01:
		if forward_speed < -1.0:
			brake_force = max_brake * throttle       # Rolling backwards: brake first.
		elif speed_kmh < max_speed_kmh:
			# Strong pull off the line, tapering toward top speed.
			var t := clampf(speed_kmh / max_speed_kmh, 0.0, 1.0)
			force = max_engine_force * throttle * lerpf(1.0, top_speed_force_ratio, t)
	else:
		brake_force = max_brake * 0.06               # Engine braking when coasting.

	is_braking = brake_force > max_brake * 0.1 or _handbrake
	engine_force = force * (0.3 if _handbrake else 1.0)
	brake = brake_force   # Sets every wheel; the rear is overridden below.

	# Handbrake: lock the rear wheels and let them slide.
	for w in _rear_wheels:
		w.wheel_friction_slip = _base_rear_grip * (handbrake_grip if _handbrake else 1.0)
		# Enough to break the rear loose and scrub speed, not a full stop.
		w.brake = max_brake * 0.6 if _handbrake else brake_force

	var speed_ratio := clampf(speed_kmh / max_speed_kmh, 0.0, 1.0)
	var steer_limit := lerpf(max_steer_angle, high_speed_steer_angle, speed_ratio)
	steering = move_toward(steering, steer_input * steer_limit, steer_speed * delta)


## The "arcade" part: forces added on top of the raycast-wheel simulation.
func _apply_arcade_forces(delta: float) -> void:
	var v := linear_velocity
	var speed := v.length()
	# Parked and at rest: leave the body alone so the physics engine can let
	# it sleep. Dozens of parked cars then cost almost nothing.
	if driver == null and speed < 0.3 and global_basis.y.y > 0.95:
		return
	var grounded := is_on_ground()

	if grounded:
		# Grip assist: remove a share of sideways velocity, less when drifting.
		var lateral := global_basis.x * v.dot(global_basis.x)
		var grip := grip_assist * (0.25 if _handbrake else 1.0)
		apply_central_force(-lateral * mass * minf(grip * delta, 1.0) / delta)
		apply_central_force(-global_basis.y * downforce * speed * speed)

	apply_central_force(-v * drag * speed)

	# Upright torque: rotate our up axis back toward world up. Only roll and
	# pitch are corrected, so steering (yaw) is untouched.
	var up := global_basis.y
	var tilt_axis := up.cross(Vector3.UP)
	var spin := angular_velocity - Vector3.UP * angular_velocity.dot(Vector3.UP)
	var strength := upright_strength * (1.0 if grounded else 0.5)
	apply_torque((tilt_axis * strength - spin * upright_damping) * mass)

	# Stuck on the roof or side? Flip back after a couple of seconds.
	if up.y < 0.3 and speed < 3.0:
		_upside_down_time += delta
		if _upside_down_time > 2.0:
			flip_upright()
	else:
		_upside_down_time = 0.0


## Scooter lean: the body (and rider) tilt into turns, more with speed.
func _update_lean(delta: float) -> void:
	var speed_ratio := clampf(absf(get_forward_speed()) * 3.6 / max_speed_kmh, 0.0, 1.0)
	var steer_ratio := steering / maxf(max_steer_angle, 0.01)
	var target := -steer_ratio * lean_angle * clampf(speed_ratio * 2.0, 0.0, 1.0)
	_body.rotation.z = lerpf(_body.rotation.z, target, clampf(6.0 * delta, 0.0, 1.0))


## Puts the vehicle back on its wheels, keeping its heading.
func flip_upright() -> void:
	var yaw := global_rotation.y
	global_transform = Transform3D(Basis(Vector3.UP, yaw), global_position + Vector3.UP * 1.0)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_upside_down_time = 0.0


# --- Interface used by the Player, camera, HUD and components -----------------

## True when the player or an AI is driving.
func has_driver() -> bool:
	return driver != null or ai_controlled


func set_driver(new_driver: Player) -> void:
	driver = new_driver
	if _rider:
		_rider.visible = shows_rider and driver != null
	if driver:
		locked = false
	driver_changed.emit(driver)


## Car alarm: the horn and lamps pulse for `seconds` (after a break-in).
func start_alarm(seconds := 6.0) -> void:
	_alarm_time = seconds


## True during the "on" half of each alarm pulse. Read by lights and sounds.
func is_alarm_beat() -> bool:
	return _alarm_time > 0.0 and fmod(_alarm_time, 0.5) > 0.25


## Signed speed along the vehicle's forward axis (m/s). Negative = reversing.
func get_forward_speed() -> float:
	return linear_velocity.dot(global_basis.z)


## World position the player must be near to get in.
func get_door_position() -> Vector3:
	return _door.global_position


## World position to drop the player at when they get out. If the door side is
## blocked (wall, other car), try the other side, then the roof.
func get_exit_position() -> Vector3:
	var candidates: Array[Vector3] = [
		_door.global_position,
		global_transform * Vector3(-_door.position.x, _door.position.y, _door.position.z),
		global_position + Vector3.UP * 2.5,
	]
	for pos in candidates:
		if _is_spot_free(pos):
			return pos
	return candidates[-1]


## True if any wheel touches the ground.
func is_on_ground() -> bool:
	for child in get_children():
		if child is VehicleWheel3D and child.is_in_contact():
			return true
	return false


## Speed in km/h, for the HUD.
func get_speed_kmh() -> float:
	return linear_velocity.length() * 3.6


## Gives this vehicle its own paint material (on every Body mesh whose name
## starts with "Paint") so recolouring one car doesn't recolour them all.
func _apply_paint() -> void:
	paint_material = StandardMaterial3D.new()
	paint_material.albedo_color = paint_color
	paint_material.metallic = 0.45
	paint_material.roughness = 0.3
	for part in _body.find_children("Paint*", "MeshInstance3D", true, false):
		part.material_override = paint_material


## Checks whether a player-sized capsule fits with its feet at the given position.
func _is_spot_free(pos: Vector3) -> bool:
	var shape := CapsuleShape3D.new()
	shape.radius = 0.4
	shape.height = 1.8
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	# Capsule centre sits 1 m up so the ground under the feet doesn't count.
	query.transform = Transform3D(Basis(), pos + Vector3.UP * 1.0)
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()
