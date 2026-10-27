class_name VehicleSpawner
extends Node3D
## Parks random vehicles on the streets as map chunks stream in, and removes
## them when their chunk streams out, so the city always looks lived in without
## simulating thousands of cars.
##
## Petit taxis and mobylettes are the most common, as on Casablanca's streets.
## Some parked cars are locked: the player can still steal them, it just takes
## a moment and sets off the alarm.
##
## The vehicle you last drove is never removed, so you can find it again.

## Vehicle scenes to pick from, and how common each one is (same order).
@export var vehicle_scenes: Array[PackedScene] = []
@export var weights: PackedFloat32Array = []
## Share of parking spots that get a vehicle.
@export_range(0.0, 1.0) var density := 0.35
## Share of parked vehicles that are locked.
@export_range(0.0, 1.0) var locked_chance := 0.4
## Upper limit on spawned vehicles alive at once.
@export var max_vehicles := 45
## Spots closer than this to the player (or another vehicle) stay empty.
@export var min_clearance := 7.0

@export var streamer: ChunkStreamer
@export var player: Player

var _by_chunk := {}          # Chunk key -> Array[Vehicle] spawned there
var _keep: Vehicle = null    # Last vehicle the player drove.
var _rng := RandomNumberGenerator.new()
var _total_weight := 0.0


func _ready() -> void:
	_rng.randomize()
	for i in vehicle_scenes.size():
		_total_weight += weights[i] if i < weights.size() else 1.0
	if streamer:
		streamer.chunk_loaded.connect(_on_chunk_loaded)
		streamer.chunk_unloaded.connect(_on_chunk_unloaded)
	if player:
		player.vehicle_entered.connect(func(v: Vehicle) -> void: _keep = v)


func _on_chunk_loaded(key: String, spots: Array) -> void:
	if vehicle_scenes.is_empty():
		return
	var list: Array = _by_chunk.get(key, [])
	_by_chunk.erase(key)
	var alive := _count()
	for spot: Dictionary in spots:
		if alive + list.size() >= max_vehicles:
			break
		if _rng.randf() > density or not _is_clear(spot["pos"]):
			continue
		var vehicle := _pick_scene().instantiate() as Vehicle
		vehicle.spawned = true
		vehicle.locked = _rng.randf() < locked_chance
		add_child(vehicle)
		vehicle.global_transform = Transform3D(Basis(Vector3.UP, spot["yaw"]), spot["pos"])
		list.append(vehicle)
	_by_chunk[key] = list


func _on_chunk_unloaded(key: String) -> void:
	# Vehicles move, so free the ones that are *now* on this chunk, wherever
	# they were spawned.
	for chunk_key: String in _by_chunk.keys():
		var list: Array = _by_chunk[chunk_key]
		for i in range(list.size() - 1, -1, -1):
			var vehicle = list[i]   # Untyped: it may already be freed.
			if not is_instance_valid(vehicle):
				list.remove_at(i)
			elif vehicle != _keep and not vehicle.has_driver() and streamer.key_at(vehicle.global_position) == key:
				vehicle.queue_free()
				list.remove_at(i)
	if _by_chunk.has(key) and _by_chunk[key].is_empty():
		_by_chunk.erase(key)


func _pick_scene() -> PackedScene:
	var roll := _rng.randf() * _total_weight
	for i in vehicle_scenes.size():
		roll -= weights[i] if i < weights.size() else 1.0
		if roll <= 0.0:
			return vehicle_scenes[i]
	return vehicle_scenes[-1]


func _is_clear(pos: Vector3) -> bool:
	if player and player.global_position.distance_to(pos) < min_clearance:
		return false
	for node in get_tree().get_nodes_in_group("vehicles"):
		if (node as Node3D).global_position.distance_to(pos) < min_clearance:
			return false
	return true


func _count() -> int:
	var n := 0
	for key in _by_chunk:
		n += _by_chunk[key].size()
	return n
