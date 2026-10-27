class_name CameraRig
extends Node3D
## Third-person orbit camera that follows either the player or a vehicle.
##
## Node layout (see scenes/camera/camera_rig.tscn):
##   CameraRig (this, follows the target's position)
##   └─ Pivot (yaw + pitch from mouse / right stick)
##      └─ SpringArm3D (pulls the camera in when a wall is in the way)
##         └─ Camera3D
##
## Each kind of target has its own framing (distance, height, FOV); vehicles
## supply their own (a scooter sits closer than a limousine). Switching target
## blends position, distance and angle over `transition_time` instead of
## cutting. While driving, the camera swings back behind the vehicle on its own
## after you stop moving the mouse.

## Framing used for a target. Tweak these in the inspector.
@export_group("On foot")
@export var foot_distance := 4.0
@export var foot_height := 1.6        ## Look-at point above the player's feet.
@export var foot_fov := 70.0

@export_group("In vehicle")
## Fallbacks; each Vehicle normally sets camera_distance/height/fov itself.
@export var car_distance := 7.5
@export var car_height := 1.6
@export var car_fov := 72.0
@export var transition_time := 0.9      ## Seconds to blend on enter/exit.
@export var car_fov_speed_boost := 14.0 ## Extra FOV at top speed (sense of speed).
@export var auto_center_delay := 1.5    ## Seconds after last look input.
@export var auto_center_speed := 2.5

@export_group("Controls")
@export var mouse_sensitivity := 0.003
@export var stick_sensitivity := 3.0    ## rad/s at full right-stick deflection.
@export var min_pitch := -70.0          ## Degrees (looking down).
@export var max_pitch := 30.0           ## Degrees (looking up).
@export var follow_speed := 12.0        ## Position smoothing; higher = snappier.
@export var zoom_speed := 6.0           ## How fast distance/FOV blend between modes.

## Node we are following. Set with follow_player() / follow_vehicle().
var target: Node3D = null

var _yaw := 0.0
var _pitch := deg_to_rad(-15.0)
var _time_since_look := 0.0
var _in_vehicle := false
var _transition := 0.0   # 1 right after switching target, eases down to 0.

@onready var _pivot: Node3D = $Pivot
@onready var _spring_arm: SpringArm3D = $Pivot/SpringArm3D
@onready var _camera: Camera3D = $Pivot/SpringArm3D/Camera3D


func _ready() -> void:
	# The rig moves on its own; it must not inherit any parent's transform.
	top_level = true
	_camera.current = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_mouse"):
		var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if captured else Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton and event.pressed \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		# Click back into the window to recapture the mouse.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_rotate_view(-event.relative.x * mouse_sensitivity, -event.relative.y * mouse_sensitivity)
	elif event.is_action_pressed("camera_reset"):
		_snap_behind_target()


func _process(delta: float) -> void:
	if target == null:
		return

	# Right-stick look.
	var stick := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	if stick != Vector2.ZERO:
		_rotate_view(-stick.x * stick_sensitivity * delta, -stick.y * stick_sensitivity * delta)

	_time_since_look += delta
	_transition = maxf(_transition - delta / transition_time, 0.0)
	if _in_vehicle:
		if _transition > 0.0:
			# Getting in: swing round behind the vehicle, easing out.
			var t := clampf(5.0 * delta * (0.5 + _transition), 0.0, 1.0)
			_yaw = lerp_angle(_yaw, _behind_yaw(), t)
			_pitch = lerpf(_pitch, deg_to_rad(-12.0), t)
		else:
			_auto_center_behind_vehicle(delta)

	_follow_target(delta)
	_update_framing(delta)
	_pivot.rotation = Vector3(_pitch, _yaw, 0.0)


# --- Public API -------------------------------------------------------------

func follow_player(player: Player) -> void:
	_set_target(player, false)


## Jumps straight to the target and behind it, with no smoothing (spawning,
## respawning after falling in the sea).
func snap_to_target() -> void:
	if target == null:
		return
	_snap_behind_target()
	_transition = 0.0
	global_position = target.global_position + Vector3.UP * _target_height()


func follow_vehicle(vehicle: Vehicle) -> void:
	_set_target(vehicle, true)


# --- Internals --------------------------------------------------------------

func _set_target(new_target: Node3D, in_vehicle: bool) -> void:
	if target != null and target != new_target:
		_transition = 1.0
	target = new_target
	_in_vehicle = in_vehicle
	# Don't let the spring arm collide with the thing it's looking at.
	_spring_arm.clear_excluded_objects()
	if new_target is CollisionObject3D:
		_spring_arm.add_excluded_object(new_target.get_rid())


func _rotate_view(yaw_delta: float, pitch_delta: float) -> void:
	_yaw = wrapf(_yaw + yaw_delta, -PI, PI)
	_pitch = clampf(_pitch + pitch_delta, deg_to_rad(min_pitch), deg_to_rad(max_pitch))
	_time_since_look = 0.0


## Yaw that places the camera directly behind the target. The SpringArm extends
## along the pivot's +Z, and our targets face +Z, so "behind" is target yaw + PI.
func _behind_yaw() -> float:
	# The player's body never rotates (only its model does), so ask it.
	var facing := (target as Player).get_facing_yaw() if target is Player else target.global_rotation.y
	return wrapf(facing + PI, -PI, PI)


func _snap_behind_target() -> void:
	if target:
		_yaw = _behind_yaw()


## When driving and the player isn't touching the camera, swing back behind the
## car. Only while moving forward, so reversing/parking doesn't spin the view.
func _auto_center_behind_vehicle(delta: float) -> void:
	if _time_since_look < auto_center_delay:
		return
	var vehicle := target as Vehicle
	if vehicle == null:
		return
	var forward_speed := vehicle.linear_velocity.dot(vehicle.global_basis.z)
	if forward_speed < 2.0:
		return
	_yaw = lerp_angle(_yaw, _behind_yaw(), clampf(auto_center_speed * delta, 0.0, 1.0))
	_pitch = lerpf(_pitch, deg_to_rad(-12.0), clampf(auto_center_speed * delta, 0.0, 1.0))


func _target_height() -> float:
	var vehicle := target as Vehicle
	if vehicle:
		return vehicle.camera_height
	return car_height if _in_vehicle else foot_height


func _follow_target(delta: float) -> void:
	var goal := target.global_position + Vector3.UP * _target_height()
	# Slower follow during a transition so the camera glides to its new target.
	var speed := follow_speed * lerpf(1.0, 0.3, _transition)
	# Exponential smoothing that behaves the same at any frame rate.
	global_position = global_position.lerp(goal, 1.0 - exp(-speed * delta))


## Smoothly blends spring length and FOV between on-foot and vehicle framing.
func _update_framing(delta: float) -> void:
	var distance := foot_distance
	var fov := foot_fov
	if _in_vehicle:
		distance = car_distance
		fov = car_fov
		var vehicle := target as Vehicle
		if vehicle:
			distance = vehicle.camera_distance
			fov = vehicle.camera_fov + car_fov_speed_boost * clampf(vehicle.get_speed_kmh() / vehicle.max_speed_kmh, 0.0, 1.0)
	var t := 1.0 - exp(-zoom_speed * lerpf(1.0, 0.5, _transition) * delta)
	_spring_arm.spring_length = lerpf(_spring_arm.spring_length, distance, t)
	_camera.fov = lerpf(_camera.fov, fov, t)
