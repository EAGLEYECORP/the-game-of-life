class_name AmbientAudio
extends Node
## Background sound of the city, mixed by where the player is:
##   - the Atlantic surf, louder the closer you are to the coastline,
##   - traffic rumble, following how many cars are around you,
##   - city murmur, busier downtown and in the daytime,
##   - seagulls now and then near the sea, by day.
## Everything is quieter inside a vehicle (and under the radio).
##
## Loops are synthesised once by AmbientSynth on a worker thread at startup.

@export var player: Player
@export var streamer: ChunkStreamer
@export var traffic: TrafficManager

var _ocean: AudioStreamPlayer
var _traffic: AudioStreamPlayer
var _city: AudioStreamPlayer
var _gull: AudioStreamPlayer
var _task := -1
var _streams: Array = []
var _timer := 0.0
var _gull_timer := 8.0
var _levels := {"ocean": -80.0, "traffic": -80.0, "city": -80.0}


func _ready() -> void:
	_ocean = _make("Ocean")
	_traffic = _make("Traffic")
	_city = _make("City")
	_gull = _make("Gull")
	var out := _streams
	_task = WorkerThreadPool.add_task(func() -> void:
		out.append_array([AmbientSynth.ocean(), AmbientSynth.traffic(), AmbientSynth.city(), AmbientSynth.gull()]))


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)


func _process(delta: float) -> void:
	if _task >= 0:
		if not WorkerThreadPool.is_task_completed(_task):
			return
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_ocean.stream = _streams[0]
		_traffic.stream = _streams[1]
		_city.stream = _streams[2]
		_gull.stream = _streams[3]
		for p in [_ocean, _traffic, _city]:
			p.volume_db = -80.0
			p.play()
	if player == null or _ocean.stream == null:
		return

	_timer -= delta
	if _timer <= 0.0:
		_timer = 0.25
		_update_targets()

	# Smooth volume changes so moving around never sounds jumpy.
	var k := clampf(delta * 1.5, 0.0, 1.0)
	_ocean.volume_db = lerpf(_ocean.volume_db, _levels["ocean"], k)
	_traffic.volume_db = lerpf(_traffic.volume_db, _levels["traffic"], k)
	_city.volume_db = lerpf(_city.volume_db, _levels["city"], k)

	# Seagulls: by day, near the coast, every so often.
	_gull_timer -= delta
	if _gull_timer <= 0.0:
		_gull_timer = randf_range(9.0, 22.0)
		var coast := _coast_distance()
		var night := DayNightCycle.current.night_factor if DayNightCycle.current else 0.0
		if coast < 250.0 and night < 0.5:
			_gull.volume_db = lerpf(-8.0, -26.0, coast / 250.0) + _vehicle_damping()
			_gull.pitch_scale = randf_range(0.9, 1.15)
			_gull.play()


func _update_targets() -> void:
	var pos := player.global_position
	var damp := _vehicle_damping()
	var night := DayNightCycle.current.night_factor if DayNightCycle.current else 0.0

	# Ocean: full on the beach, gone ~700 m inland.
	var coast := _coast_distance()
	_levels["ocean"] = lerpf(-6.0, -60.0, clampf(coast / 700.0, 0.0, 1.0)) + damp

	# Traffic: count cars within 80 m.
	var cars := 0
	if traffic:
		for c in traffic._cars:
			if c.global_position.distance_squared_to(pos) < 80.0 * 80.0:
				cars += 1
	_levels["traffic"] = lerpf(-34.0, -10.0, clampf(cars / 10.0, 0.0, 1.0)) + damp

	# City murmur: busier where there are more people, quieter at night.
	var busy := streamer.get_area_value(pos, "pedestrians", 1.0) if streamer else 1.0
	_levels["city"] = lerpf(-24.0, -12.0, clampf((busy - 0.8) / 0.8, 0.0, 1.0)) - night * 8.0 + damp


func _coast_distance() -> float:
	return streamer.get_coast_distance(player.global_position) if streamer else INF


## Inside a car the outside world is muffled (not on a moped).
func _vehicle_damping() -> float:
	return -8.0 if player.current_vehicle and not player.current_vehicle.two_wheeler else 0.0


func _make(n: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = n
	add_child(p)
	return p
