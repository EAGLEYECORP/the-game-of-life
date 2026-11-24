class_name RadioSystem
extends Node
## The car radio: four Casablanca-flavoured stations, plus "off".
##
## Each station plays real audio files if you put some in
## assets/audio/radio/<station id>/ (wav, ogg or mp3); otherwise it plays
## placeholder tracks synthesised by MusicSynth on a worker thread, with a
## station ident chime between songs.
##
## Like a real radio, stations keep "playing" while you're tuned elsewhere:
## tuning in starts mid-song. R / Q change station while driving.

signal station_changed(text: String)

const STATIONS := [
	{"id": "chaabi", "name": "Casa Chaabi 101.3", "style": "chaabi",
		"titles": ["Chaabi d'la Corniche", "Lila f Derb Sultan", "Zahia"]},
	{"id": "gnawa", "name": "Gnawa Bladi 96.8", "style": "gnawa",
		"titles": ["Lalla Mira (instrumental)", "Guembri Night", "Sidi Moussa Groove"]},
	{"id": "andalous", "name": "Andalous FM 89.5", "style": "andalous",
		"titles": ["Nouba du soir", "Touchia Ramal", "Bab Marrakech"]},
	{"id": "rai", "name": "Raï Corniche 94.7", "style": "rai",
		"titles": ["Ya Rayah Casa", "Ain Diab 3am", "Lmima"]},
]
const TRACKS_PER_STATION := 3
const RADIO_DIR := "res://assets/audio/radio"

## Which station a vehicle tunes to when you get in (by display_name).
const VEHICLE_DEFAULTS := {"Petit Taxi": 0, "Grand Taxi": 2, "Mobylette": 3}

@export var player: Player
@export var volume_db := -7.0

## -1 = off.
var station := -1

var _player_audio: AudioStreamPlayer
var _tracks := {}          # station index -> Array of [title, AudioStream]
var _jingles := {}         # station index -> AudioStream
var _queue: Array = []     # [station, track] still to synthesise
var _task := -1
var _task_result: Array = []
var _mutex := Mutex.new()
var _clock := 0.0          # Seconds since start; drives the "live" position.
var _current_track := -1
var _in_vehicle := false
var _last_station := -1


func _ready() -> void:
	_player_audio = AudioStreamPlayer.new()
	_player_audio.volume_db = volume_db
	_player_audio.finished.connect(_on_finished)
	add_child(_player_audio)
	for i in STATIONS.size():
		_load_real_files(i)
		_jingles[i] = null
		for t in TRACKS_PER_STATION:
			if not _has_real_files(i):
				_queue.append([i, t])
	if player:
		player.vehicle_entered.connect(_on_vehicle_entered)
		player.vehicle_exited.connect(_on_vehicle_exited)


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
	_player_audio.stop()
	_player_audio.stream = null
	_tracks.clear()
	_jingles.clear()
	_task_result.clear()


func _process(delta: float) -> void:
	_clock += delta
	_pump_generation()


func _unhandled_input(event: InputEvent) -> void:
	if not _in_vehicle:
		return
	if event.is_action_pressed("radio_next"):
		get_viewport().set_input_as_handled()
		tune(station + 1 if station + 1 < STATIONS.size() else -1)
	elif event.is_action_pressed("radio_prev"):
		get_viewport().set_input_as_handled()
		tune(station - 1 if station > -1 else STATIONS.size() - 1)


## Switches to `index` (-1 = off) and starts playing if in a vehicle.
func tune(index: int) -> void:
	station = index
	_last_station = index
	if station < 0:
		_player_audio.stop()
		station_changed.emit("Radio off")
		return
	# Generate this station's songs before the others.
	_queue.sort_custom(func(a, b): return int(a[0] == station) > int(b[0] == station))
	_start_playing(true)


# --- Playback -----------------------------------------------------------------------

func _start_playing(mid_song: bool) -> void:
	if station < 0 or not _in_vehicle:
		return
	var tracks: Array = _tracks.get(station, [])
	if tracks.is_empty():
		_player_audio.stop()
		station_changed.emit("%s — tuning..." % STATIONS[station]["name"])
		return
	# The station's clock decides which song is on and how far into it.
	var lengths := 0.0
	for tr in tracks:
		lengths += tr[1].get_length()
	var at := fposmod(_clock + station * 37.0, lengths) if mid_song else 0.0
	var idx := 0
	while at > tracks[idx][1].get_length():
		at -= tracks[idx][1].get_length()
		idx = (idx + 1) % tracks.size()
	_current_track = idx
	_player_audio.stream = tracks[idx][1]
	_player_audio.play(at if mid_song else 0.0)
	station_changed.emit("%s\n%s" % [STATIONS[station]["name"], tracks[idx][0]])


## Song over: a station ident, then the next song.
func _on_finished() -> void:
	if station < 0 or not _in_vehicle:
		return
	var tracks: Array = _tracks.get(station, [])
	if _player_audio.stream != _jingles.get(station) and _jingles.get(station):
		_player_audio.stream = _jingles[station]
		_player_audio.play()
		return
	if tracks.is_empty():
		return
	_current_track = (_current_track + 1) % tracks.size()
	_player_audio.stream = tracks[_current_track][1]
	_player_audio.play()
	station_changed.emit("%s\n%s" % [STATIONS[station]["name"], tracks[_current_track][0]])


func _on_vehicle_entered(vehicle: Vehicle) -> void:
	_in_vehicle = true
	var pick: int = VEHICLE_DEFAULTS.get(vehicle.display_name, _last_station)
	if pick < 0 and _last_station < 0:
		pick = randi() % STATIONS.size()
	tune(pick)


func _on_vehicle_exited(_vehicle: Vehicle) -> void:
	_in_vehicle = false
	_player_audio.stop()


# --- Content ----------------------------------------------------------------------

## Generates one placeholder track at a time on a worker thread.
func _pump_generation() -> void:
	if _task >= 0:
		if not WorkerThreadPool.is_task_completed(_task):
			return
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_mutex.lock()
		var res := _task_result.duplicate()
		_task_result.clear()
		_mutex.unlock()
		for r in res:
			var s: int = r[0]
			if not _tracks.has(s):
				_tracks[s] = []
			_tracks[s].append([r[1], r[2]])
			if _jingles[s] == null:
				_jingles[s] = r[3]
			# First song for the station we're listening to: start it.
			if s == station and _tracks[s].size() == 1 and _in_vehicle:
				_start_playing(true)
	if _queue.is_empty():
		return
	var job: Array = _queue.pop_front()
	var st: Dictionary = STATIONS[job[0]]
	var title: String = st["titles"][job[1] % st["titles"].size()]
	var seed: int = hash(st["id"]) + job[1] * 7919
	_task = WorkerThreadPool.add_task(func() -> void:
		var wav := MusicSynth.track(st["style"], seed)
		var chime := MusicSynth.jingle(hash(st["id"]))
		_mutex.lock()
		_task_result.append([job[0], title + "  (placeholder)", wav, chime])
		_mutex.unlock())


func _has_real_files(index: int) -> bool:
	return _tracks.has(index) and not _tracks[index].is_empty()


## Loads real songs from assets/audio/radio/<id>/ if there are any.
func _load_real_files(index: int) -> void:
	var dir := RADIO_DIR.path_join(STATIONS[index]["id"])
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		# Exported games only list the .import side files.
		var file := f.trim_suffix(".import")
		if file.get_extension().to_lower() in ["wav", "ogg", "mp3"] and not _already_listed(index, file):
			var stream := load(dir.path_join(file)) as AudioStream
			if stream:
				if not _tracks.has(index):
					_tracks[index] = []
				_tracks[index].append([file.get_basename().replace("_", " "), stream])


func _already_listed(index: int, file: String) -> bool:
	for tr in _tracks.get(index, []):
		if tr[0] == file.get_basename().replace("_", " "):
			return true
	return false
