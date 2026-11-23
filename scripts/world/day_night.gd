class_name DayNightCycle
extends Node
## Time of day for Casablanca: sun path, sky, light colours and coastal haze.
##
## The sun rises over the land (east) and sets into the Atlantic (west).
## Colours come from hourly keyframes tuned for the coast: a misty marine layer
## at dawn, bright hazy midday, a long golden hour, blue nights with a moon.
## Fog thickens near the sea and in the morning, like the real Corniche.
##
## Publishes `night_factor` (0 day .. 1 night) as a global shader parameter so
## building windows and street lamps light up, and as a property for scripts.
##
## Performance: re-rendering the sky's reflections is the expensive part, so
## the sky is updated a few times per second at most, incrementally.

signal hour_changed(hour: int)

## The running cycle, for scripts that just need "is it night?".
static var current: DayNightCycle

@export var sun: DirectionalLight3D
@export var world_environment: WorldEnvironment
@export_range(0.0, 24.0) var start_hour := 18.0   ## Golden hour by default.
@export var day_length_minutes := 24.0             ## Real minutes per game day.
@export var time_skip_speed := 240.0               ## While holding T.
## Extra fog multiplier right on the coast (fades out 600 m inland).
@export var coastal_haze := 0.9

## Current time, 0..24.
var hour := 18.0
## 0 in daylight, 1 at night, smooth in between.
var night_factor := 0.0

## Set by main.gd so the haze knows where the player is relative to the sea.
var focus: Node3D
var streamer: ChunkStreamer

# Hour -> [sun energy, sun colour, sky top, sky horizon, fog colour, fog density, ambient]
const KEYS := [
	[0.0, 0.10, Color(0.55, 0.65, 1.0), Color(0.02, 0.03, 0.07), Color(0.06, 0.08, 0.13), Color(0.05, 0.07, 0.11), 0.0022, 0.25],
	[5.0, 0.06, Color(0.55, 0.65, 1.0), Color(0.04, 0.05, 0.12), Color(0.18, 0.16, 0.22), Color(0.16, 0.16, 0.2), 0.0040, 0.25],
	[6.5, 0.45, Color(1.0, 0.62, 0.42), Color(0.22, 0.32, 0.55), Color(0.92, 0.66, 0.5), Color(0.75, 0.66, 0.6), 0.0048, 0.45],
	[8.5, 1.0, Color(1.0, 0.88, 0.74), Color(0.3, 0.5, 0.8), Color(0.82, 0.82, 0.84), Color(0.82, 0.84, 0.86), 0.0030, 0.8],
	[13.0, 1.3, Color(1.0, 0.97, 0.92), Color(0.24, 0.48, 0.86), Color(0.76, 0.82, 0.88), Color(0.8, 0.84, 0.88), 0.0017, 1.0],
	[17.0, 1.1, Color(1.0, 0.88, 0.7), Color(0.28, 0.46, 0.78), Color(0.9, 0.8, 0.68), Color(0.86, 0.8, 0.72), 0.0021, 0.85],
	[19.0, 0.55, Color(1.0, 0.52, 0.28), Color(0.22, 0.27, 0.52), Color(1.0, 0.52, 0.3), Color(0.9, 0.58, 0.42), 0.0032, 0.55],
	[20.3, 0.06, Color(0.55, 0.65, 1.0), Color(0.05, 0.06, 0.15), Color(0.32, 0.18, 0.22), Color(0.18, 0.14, 0.18), 0.0028, 0.3],
	[22.0, 0.10, Color(0.55, 0.65, 1.0), Color(0.02, 0.03, 0.07), Color(0.06, 0.08, 0.13), Color(0.05, 0.07, 0.11), 0.0022, 0.25],
	[24.0, 0.10, Color(0.55, 0.65, 1.0), Color(0.02, 0.03, 0.07), Color(0.06, 0.08, 0.13), Color(0.05, 0.07, 0.11), 0.0022, 0.25],
]

var _sky_timer := 0.0
var _haze := 1.0
var _haze_timer := 0.0
var _last_hour := -1


func _ready() -> void:
	current = self
	hour = start_hour
	var env := world_environment.environment
	if env.sky:
		# Cheap reflections: small radiance map, refreshed over a few frames.
		env.sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
		env.sky.radiance_size = Sky.RADIANCE_SIZE_128
	_apply(true)


func _exit_tree() -> void:
	if current == self:
		current = null


func is_night() -> bool:
	return night_factor > 0.5


## "18:42"
func clock_text() -> String:
	return "%02d:%02d" % [int(hour), int(fmod(hour, 1.0) * 60.0)]


func _process(delta: float) -> void:
	var speed := 24.0 / (day_length_minutes * 60.0)
	if Input.is_action_pressed("time_skip"):
		speed *= time_skip_speed
	hour = fposmod(hour + delta * speed, 24.0)
	if int(hour) != _last_hour:
		_last_hour = int(hour)
		hour_changed.emit(_last_hour)

	# Coastal haze: thicker near the water. Checked twice a second.
	_haze_timer -= delta
	if _haze_timer <= 0.0:
		_haze_timer = 0.5
		var target := 1.0
		if focus and streamer:
			var d := streamer.get_coast_distance(focus.global_position)
			target = 1.0 + coastal_haze * clampf(1.0 - d / 600.0, 0.0, 1.0)
		_haze = target if _haze <= 0.0 else lerpf(_haze, target, 0.3)

	_sky_timer -= delta
	_apply(_sky_timer <= 0.0)
	if _sky_timer <= 0.0:
		_sky_timer = 0.25


## Sets lights, fog and (when `update_sky`) the sky colours for the hour.
func _apply(update_sky: bool) -> void:
	var k := _sample(hour)
	var env := world_environment.environment

	# Sun path: rises in the east (+X) at ~6:30, highest at 13:00, sets in the
	# west (-X) at ~19:30. At night the same light plays the moon.
	var day_t := (hour - 6.5) / 13.0                    # 0 sunrise .. 1 sunset
	var elevation := sin(day_t * PI) * 68.0
	var azimuth := lerpf(90.0, 270.0, clampf(day_t, 0.0, 1.0))
	var is_moon := elevation < -2.0
	if is_moon:
		# Moon: opposite arc, gentle and high.
		var night_t := fposmod(hour - 19.5, 24.0) / 11.0
		elevation = 15.0 + sin(clampf(night_t, 0.0, 1.0) * PI) * 40.0
		azimuth = lerpf(90.0, 270.0, clampf(night_t, 0.0, 1.0))
	elevation = maxf(elevation, 3.0)
	sun.rotation_degrees = Vector3(-elevation, azimuth, 0.0)
	sun.light_energy = k[0]
	sun.light_color = k[1]
	# Long moon shadows aren't worth their cost.
	sun.shadow_enabled = not is_moon

	night_factor = clampf(1.0 - (k[0] - 0.08) / 0.4, 0.0, 1.0)
	RenderingServer.global_shader_parameter_set("night_factor", night_factor)

	env.ambient_light_energy = k[6]
	env.fog_light_color = k[4]
	env.fog_density = k[5] * _haze
	env.fog_sun_scatter = 0.35 if not is_moon else 0.0

	if update_sky and env.sky and env.sky.sky_material is ProceduralSkyMaterial:
		var sky := env.sky.sky_material as ProceduralSkyMaterial
		sky.sky_top_color = k[2]
		sky.sky_horizon_color = k[3]
		sky.ground_horizon_color = k[3]
		sky.ground_bottom_color = k[2].darkened(0.6)
		sky.sun_angle_max = 20.0 if not is_moon else 4.0
		sky.sky_energy_multiplier = lerpf(1.0, 0.4, night_factor)


## Interpolated keyframe at `h`: [energy, sun col, top, horizon, fog col, fog density, ambient].
func _sample(h: float) -> Array:
	for i in KEYS.size() - 1:
		var a: Array = KEYS[i]
		var b: Array = KEYS[i + 1]
		if h >= a[0] and h <= b[0]:
			var t := smoothstep(0.0, 1.0, (h - a[0]) / (b[0] - a[0]))
			var out := []
			for j in range(1, a.size()):
				out.append(lerp(a[j], b[j], t))
			return out
	return KEYS[0].slice(1)
