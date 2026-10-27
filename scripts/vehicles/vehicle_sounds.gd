class_name VehicleSounds
extends Node3D
## Engine hum and horn for a Vehicle, synthesised by SoundSynth (no audio files).
##
## Add as a child of a Vehicle. The engine runs while someone drives and its
## pitch climbs through fake gears with speed. The horn plays while the driver
## holds H, and pulses on its own when the car alarm goes off.

## Horn style, see SoundSynth.HORNS: car, taxi, luxury, old, scooter.
@export var horn_style := "car"
## Engine style, see SoundSynth.ENGINES: petrol, diesel, v8, two_stroke.
@export var engine_style := "petrol"
@export var idle_pitch := 1.0
@export var max_pitch := 2.6       ## Pitch at the top of each gear.
@export var gears := 5
@export var engine_volume_db := -6.0
@export var horn_volume_db := 0.0

@onready var _vehicle: Vehicle = get_parent()

var _engine: AudioStreamPlayer3D
var _horn: AudioStreamPlayer3D


func _ready() -> void:
	_engine = _make_player("Engine", SoundSynth.engine(engine_style), engine_volume_db)
	_horn = _make_player("Horn", SoundSynth.horn(horn_style), horn_volume_db)
	_horn.max_distance = 150.0


func _process(delta: float) -> void:
	_update_engine(delta)
	var honk := _vehicle.horn_pressed or _vehicle.is_alarm_beat()
	if honk and not _horn.playing:
		_horn.play()
	elif not honk and _horn.playing:
		_horn.stop()


func _update_engine(delta: float) -> void:
	if not _vehicle.has_driver():
		if _engine.playing:
			_engine.stop()
		return
	if not _engine.playing:
		_engine.play()

	# Fake gearbox: within each gear the pitch rises, then drops at the shift.
	var ratio := clampf(absf(_vehicle.get_forward_speed()) * 3.6 / _vehicle.max_speed_kmh, 0.0, 1.0)
	var in_gear := ratio * gears
	var gear := mini(int(in_gear), gears - 1)
	var within := in_gear - gear
	var top := lerpf(max_pitch * 0.8, max_pitch, float(gear) / maxf(gears - 1, 1))
	var target := lerpf(idle_pitch * (1.0 + 0.15 * gear), top, within)
	# Revving with the throttle while standing still.
	target = maxf(target, idle_pitch * (1.0 + _vehicle.throttle * 0.6))
	_engine.pitch_scale = lerpf(_engine.pitch_scale, target, clampf(8.0 * delta, 0.0, 1.0))
	_engine.volume_db = engine_volume_db + lerpf(-4.0, 2.0, _vehicle.throttle)


func _make_player(player_name: String, stream: AudioStream, volume: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.name = player_name
	p.stream = stream
	p.volume_db = volume
	p.unit_size = 6.0
	p.max_distance = 80.0
	add_child(p)
	return p
