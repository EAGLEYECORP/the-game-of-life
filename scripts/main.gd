extends Node3D
## Root of the game. Wires the player, camera, HUD and map streamer together.
##
## The player only announces what happens (entered a car, hint changed...);
## this script decides who reacts. Keeping that wiring here means Player,
## Vehicle and CameraRig don't need to know about each other's scenes.
##
## It also owns the "world rules" that span several systems:
##   - waiting for the map around the spawn to stream in before enabling physics,
##   - placing the player and cars at the spawn points from the OSM import,
##   - freezing parked cars whose ground isn't loaded,
##   - respawning on dry land after driving or falling into the sea.

## Below this height the player/car is in the sea and gets respawned. The map
## is flat at y = 0, so anything this low has gone over the water's edge (a
## car tipping nose-first off the quay can hang there instead of sinking).
const FALL_LIMIT := -0.8

@onready var _player: Player = $Player
@onready var _camera: CameraRig = $CameraRig
@onready var _hud: HUD = $HUD
@onready var _streamer: ChunkStreamer = $Casablanca/ChunkStreamer
@onready var _vehicles: Node3D = $Vehicles

var _safe_transform: Transform3D   # Last spot the player/car stood on solid ground.
var _safe_timer := 0.0
var _district_timer := 0.0
var _map_ready := false


func _ready() -> void:
	_player.vehicle_entered.connect(_on_vehicle_entered)
	_player.vehicle_exited.connect(_on_vehicle_exited)
	_player.interaction_hint_changed.connect(_hud.set_hint)

	if _streamer.has_data:
		_place_at_spawn_points()

	# Hold the player in place until the ground under them has streamed in.
	_player.set_physics_process(false)
	_player.set_process_unhandled_input(false)
	_safe_transform = _player.global_transform

	_camera.follow_player(_player)
	_camera.snap_to_target()

	_hud.set_notice("Loading Casablanca..." if _streamer.has_data
		else "Placeholder city: import OpenStreetMap data to play in the real Casablanca (see README).")
	_streamer.initial_area_ready.connect(_on_map_ready, CONNECT_ONE_SHOT)
	_streamer.set_focus(_player)


func _on_map_ready() -> void:
	_map_ready = true
	_player.set_physics_process(true)
	_player.set_process_unhandled_input(true)
	if _streamer.has_data:
		_hud.set_notice("")
		_hud.set_attribution(_streamer.manifest.get("attribution", "© OpenStreetMap contributors"))


## Moves the player and parked cars to the spots chosen by the OSM importer.
func _place_at_spawn_points() -> void:
	var spawn: Dictionary = _streamer.manifest.get("spawn", {})
	if spawn.has("pos"):
		var p: Array = spawn["pos"]
		_player.global_position = Vector3(p[0], p[1], p[2])
		_player.face(spawn.get("yaw", 0.0))

	var spots: Array = _streamer.manifest.get("vehicle_spawns", [])
	var cars := _vehicles.get_children()
	for i in cars.size():
		var car := cars[i] as Vehicle
		if i < spots.size():
			var s: Array = spots[i]["pos"]
			car.global_transform = Transform3D(Basis(Vector3.UP, spots[i]["yaw"]), Vector3(s[0], s[1], s[2]))
		else:
			# Not enough road spots found: line extra cars up next to the player.
			car.global_transform = Transform3D(Basis(), _player.global_position + Vector3(4.0 * (i + 1), 0.6, 4.0))


func _physics_process(delta: float) -> void:
	_freeze_cars_without_ground()
	if _map_ready:
		_track_safe_position(delta)


func _process(delta: float) -> void:
	_district_timer -= delta
	if _district_timer <= 0.0:
		_district_timer = 0.5
		_hud.set_district(_streamer.get_area_name(_player.global_position))


## Parked cars outside the streamed area would fall through the missing
## ground, so they're frozen until their chunk loads.
func _freeze_cars_without_ground() -> void:
	for car: Vehicle in _vehicles.get_children():
		if car.has_driver():
			continue
		var should_freeze := not _map_ready or not _streamer.is_loaded_at(car.global_position)
		if car.freeze != should_freeze:
			car.freeze = should_freeze


## Remembers where the player (or their car) last stood on solid ground and
## puts them back there if they end up in the sea.
func _track_safe_position(delta: float) -> void:
	var car := _player.current_vehicle
	var body: Node3D = car if car else _player

	if body.global_position.y < FALL_LIMIT:
		_respawn(body)
		return

	_safe_timer -= delta
	if _safe_timer > 0.0:
		return
	_safe_timer = 0.5
	var grounded := car.is_on_ground() if car else _player.is_on_floor()
	if grounded and body.global_position.y > -0.3:
		# Keep only position + heading so a tilted car respawns upright.
		var yaw := body.global_rotation.y if car else _player.get_facing_yaw()
		_safe_transform = Transform3D(Basis(Vector3.UP, yaw), body.global_position)


func _respawn(body: Node3D) -> void:
	var t := _safe_transform
	t.origin.y += 0.5
	if body is Vehicle:
		var car := body as Vehicle
		car.global_transform = t
		car.linear_velocity = Vector3.ZERO
		car.angular_velocity = Vector3.ZERO
	else:
		_player.global_position = t.origin
		_player.velocity = Vector3.ZERO
	_camera.snap_to_target()


func _on_vehicle_entered(vehicle: Vehicle) -> void:
	_camera.follow_vehicle(vehicle)
	_hud.show_vehicle(vehicle)


func _on_vehicle_exited(_vehicle: Vehicle) -> void:
	_camera.follow_player(_player)
	_hud.show_vehicle(null)
