class_name Player
extends CharacterBody3D
## On-foot player controller: walk, run, jump, and enter vehicles.
##
## Movement is relative to the active camera, so "forward" is always "away from
## the camera", like most third-person games. The character's visual model turns
## smoothly to face the direction it is moving.

## Emitted when the player gets into a vehicle. The camera listens to this.
signal vehicle_entered(vehicle: Vehicle)
## Emitted when the player gets out of a vehicle.
signal vehicle_exited(vehicle: Vehicle)
## Emitted when the on-screen interaction hint changes ("" = hide it).
signal interaction_hint_changed(text: String)

@export_group("Movement")
@export var walk_speed := 4.5
@export var run_speed := 8.5
@export var acceleration := 12.0     ## How fast we reach target speed on the ground.
@export var air_control := 3.0       ## Lower = less steering while airborne.
@export var jump_velocity := 5.5
@export var turn_speed := 10.0       ## How fast the model rotates to face movement.

@export_group("Interaction")
@export var vehicle_reach := 3.5     ## Max distance (m) to a vehicle's door to enter it.
@export var break_in_time := 1.2     ## Seconds to break into a locked car.

## Vehicle we are currently driving, or null when on foot.
var current_vehicle: Vehicle = null

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _nearby_vehicle: Vehicle = null
# Locked car being broken into, and time left. Movement is blocked meanwhile.
var _breaking_into: Vehicle = null
var _break_in_left := 0.0

@onready var _model: Node3D = $Model
@onready var _collision: CollisionShape3D = $CollisionShape3D


func _physics_process(delta: float) -> void:
	_apply_gravity(delta)
	if _breaking_into:
		_update_break_in(delta)
	else:
		_handle_jump()
		_handle_movement(delta)
	move_and_slide()
	if not _breaking_into:
		_update_nearby_vehicle()


func _unhandled_input(event: InputEvent) -> void:
	# Using _unhandled_input (not polling in _physics_process) lets us mark the
	# key press as handled, so the vehicle doesn't also see the same F press and
	# kick us straight back out.
	if event.is_action_pressed("interact") and _nearby_vehicle != null and not _breaking_into:
		get_viewport().set_input_as_handled()
		if _nearby_vehicle.locked:
			_start_break_in(_nearby_vehicle)
		else:
			enter_vehicle(_nearby_vehicle)


# --- Movement ---------------------------------------------------------------

func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta


func _handle_jump() -> void:
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity


func _handle_movement(delta: float) -> void:
	# Raw stick / WASD input. x = right, y = back (Godot's 2D convention).
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := _camera_relative(input)

	var speed := run_speed if Input.is_action_pressed("sprint") else walk_speed
	var target := direction * speed
	var accel := acceleration if is_on_floor() else air_control

	# Only the horizontal part of the velocity is steered; y belongs to gravity.
	velocity.x = move_toward(velocity.x, target.x, accel * speed * delta)
	velocity.z = move_toward(velocity.z, target.z, accel * speed * delta)

	# Turn the model (not the body) toward where we're going.
	if direction.length_squared() > 0.001:
		var target_yaw := atan2(direction.x, direction.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, target_yaw, turn_speed * delta)


## Converts 2D input into a world-space direction on the ground plane, based on
## where the active camera is looking.
func _camera_relative(input: Vector2) -> Vector3:
	if input == Vector2.ZERO:
		return Vector3.ZERO
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return Vector3(input.x, 0.0, input.y).normalized()
	var basis := camera.global_transform.basis
	# Flatten camera axes so looking up/down doesn't make us walk into the ground.
	var forward := Vector3(-basis.z.x, 0.0, -basis.z.z).normalized()
	var right := Vector3(basis.x.x, 0.0, basis.x.z).normalized()
	var dir := right * input.x - forward * input.y
	return dir.normalized() if dir.length() > 1.0 else dir


## Turns the character to face `yaw` (radians, +Z-forward like the vehicles).
func face(yaw: float) -> void:
	_model.rotation.y = yaw


## Direction the character is facing, for the camera's "snap behind" logic.
func get_facing_yaw() -> float:
	return _model.global_rotation.y


# --- Vehicles ---------------------------------------------------------------

## Finds the closest free vehicle whose door is within reach and updates the HUD.
func _update_nearby_vehicle() -> void:
	var best: Vehicle = null
	var best_dist := vehicle_reach
	for node in get_tree().get_nodes_in_group("vehicles"):
		var vehicle := node as Vehicle
		if vehicle == null or vehicle.has_driver():
			continue
		var dist := global_position.distance_to(vehicle.get_door_position())
		if dist < best_dist:
			best_dist = dist
			best = vehicle

	if best != _nearby_vehicle:
		_nearby_vehicle = best
		if best == null:
			interaction_hint_changed.emit("")
		elif best.locked:
			interaction_hint_changed.emit("Press F to steal the %s (locked)" % best.display_name)
		else:
			interaction_hint_changed.emit("Press F to drive the %s" % best.display_name)


## Locked car: stand at the door for a moment, then the alarm goes off and
## we're in. GTA rules.
func _start_break_in(vehicle: Vehicle) -> void:
	_breaking_into = vehicle
	_break_in_left = break_in_time
	velocity.x = 0.0
	velocity.z = 0.0
	# Face the car while working on the lock.
	var to_car := vehicle.global_position - global_position
	face(atan2(to_car.x, to_car.z))
	interaction_hint_changed.emit("Breaking into the %s..." % vehicle.display_name)


func _update_break_in(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	_break_in_left -= delta
	var vehicle := _breaking_into
	# Someone else took it, or it got pushed away: give up.
	if vehicle.has_driver() or global_position.distance_to(vehicle.get_door_position()) > vehicle_reach * 1.5:
		_breaking_into = null
		_nearby_vehicle = null
		interaction_hint_changed.emit("")
		return
	if _break_in_left <= 0.0:
		_breaking_into = null
		vehicle.locked = false
		vehicle.start_alarm()
		enter_vehicle(vehicle)


## Puts the player in the driver's seat. The player node stays in the scene but
## is hidden, has no collision and stops processing until it exits.
func enter_vehicle(vehicle: Vehicle) -> void:
	if current_vehicle != null or vehicle.has_driver():
		return
	current_vehicle = vehicle
	_nearby_vehicle = null
	interaction_hint_changed.emit("")

	_set_on_foot_active(false)
	velocity = Vector3.ZERO
	vehicle.set_driver(self)
	vehicle_entered.emit(vehicle)


## Gets out of the current vehicle and places the player next to its door.
func exit_vehicle() -> void:
	if current_vehicle == null:
		return
	var vehicle := current_vehicle
	current_vehicle = null

	vehicle.set_driver(null)
	global_position = vehicle.get_exit_position()
	# Face the same way the car was facing (model forward is +Z).
	_model.rotation.y = vehicle.global_rotation.y
	velocity = Vector3.ZERO
	_set_on_foot_active(true)
	vehicle_exited.emit(vehicle)


## Toggles everything that makes the on-foot character "exist" in the world.
func _set_on_foot_active(active: bool) -> void:
	visible = active
	# set_deferred: changing collision during a physics callback is not allowed.
	_collision.set_deferred("disabled", not active)
	set_physics_process(active)
	set_process_unhandled_input(active)
