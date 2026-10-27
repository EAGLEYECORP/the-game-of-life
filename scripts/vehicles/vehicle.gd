class_name Vehicle
extends VehicleBody3D
## Drivable car built on Godot's VehicleBody3D (raycast-wheel physics).
##
## The car only reads input while a driver is inside. Without a driver it keeps
## the brakes on so parked cars don't roll away.
##
## Local axes: +Z is the front of the car, +X is the driver's (left) side.

@export var display_name := "Dacia"
## Body colour. Each placed car can have its own (Casablanca's petit taxis are red).
@export var paint_color := Color(0.95, 0.75, 0.1)

@export_group("Engine")
@export var max_engine_force := 2800.0   ## Forward push at full throttle (N).
@export var max_reverse_force := 1400.0
@export var max_brake := 50.0            ## Brake strength when slowing down.
@export var max_speed_kmh := 140.0       ## Engine cuts out above this.

@export_group("Steering")
@export var max_steer_angle := 0.55      ## Radians (~31 degrees) at low speed.
@export var high_speed_steer_angle := 0.18 ## Radians at max speed, for stability.
@export var steer_speed := 3.0           ## How fast the wheels turn (rad/s).

## The player currently driving, or null.
var driver: Player = null

@onready var _seat: Marker3D = $Seat
@onready var _door: Marker3D = $DoorExit


func _ready() -> void:
	add_to_group("vehicles")
	brake = max_brake
	_apply_paint()


func _physics_process(delta: float) -> void:
	if driver == null:
		engine_force = 0.0
		steering = move_toward(steering, 0.0, steer_speed * delta)
		brake = max_brake
		return

	_drive(delta)
	# Keep the hidden player glued to the seat so anything that asks "where is
	# the player?" (minimap, AI, saving...) gets a sensible answer.
	driver.global_position = _seat.global_position


func _unhandled_input(event: InputEvent) -> void:
	if driver != null and event.is_action_pressed("interact"):
		get_viewport().set_input_as_handled()
		driver.exit_vehicle()


func _drive(delta: float) -> void:
	var throttle := Input.get_action_strength("move_forward")
	var reverse := Input.get_action_strength("move_back")
	var steer_input := Input.get_axis("move_right", "move_left") # Left = positive.

	# Signed speed along the car's forward axis (m/s). Negative = reversing.
	var forward_speed := linear_velocity.dot(global_basis.z)
	var speed_kmh := absf(forward_speed) * 3.6

	engine_force = 0.0
	brake = 0.0

	if throttle > 0.0:
		if forward_speed < -1.0:
			brake = max_brake * throttle         # Rolling backwards: brake first.
		elif speed_kmh < max_speed_kmh:
			engine_force = max_engine_force * throttle
	elif reverse > 0.0:
		if forward_speed > 1.0:
			brake = max_brake * reverse          # Rolling forwards: brake first.
		else:
			engine_force = -max_reverse_force * reverse
	else:
		brake = max_brake * 0.08                 # Light engine braking when coasting.

	if Input.is_action_pressed("handbrake"):
		brake = max_brake * 1.5
		engine_force = 0.0

	# Less steering lock at high speed keeps the car from flipping.
	var speed_ratio := clampf(speed_kmh / max_speed_kmh, 0.0, 1.0)
	var steer_limit := lerpf(max_steer_angle, high_speed_steer_angle, speed_ratio)
	steering = move_toward(steering, steer_input * steer_limit, steer_speed * delta)


# --- Interface used by the Player and the camera ---------------------------

func has_driver() -> bool:
	return driver != null


func set_driver(new_driver: Player) -> void:
	driver = new_driver


## World position the player must be near to get in.
func get_door_position() -> Vector3:
	return _door.global_position


## World position to drop the player at when they get out. If the door side is
## blocked (wall, other car), try the passenger side, then the roof.
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


## Gives this car its own copy of the paint material so recolouring one car
## doesn't recolour every car sharing the scene.
func _apply_paint() -> void:
	var paint := StandardMaterial3D.new()
	paint.albedo_color = paint_color
	paint.metallic = 0.4
	paint.roughness = 0.35
	for part: MeshInstance3D in [$Body/Chassis, $Body/Cabin]:
		part.material_override = paint


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
