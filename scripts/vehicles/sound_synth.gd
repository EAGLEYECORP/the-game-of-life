class_name SoundSynth
extends RefCounted
## Generates the vehicle sounds (horns, engines) in code, so the game needs no
## audio files. Each sound is a short looping AudioStreamWAV built once and
## cached; every car of the same style shares it.
##
## All frequencies are whole numbers of Hz and every loop lasts exactly one
## second, so each loop holds a whole number of cycles and repeats without
## clicks.

const MIX_RATE := 22050

## Horn styles: frequencies (Hz) played together, and how "square" the tone is
## (0 = pure sine, 1 = harsh buzz).
const HORNS := {
	"car": {"freqs": [350, 440], "buzz": 0.6},
	"taxi": {"freqs": [400, 500], "buzz": 0.75},      # The Casablanca rush-hour chorus.
	"luxury": {"freqs": [300, 375, 450], "buzz": 0.4}, # Deep three-tone chord.
	"old": {"freqs": [420], "buzz": 0.9},             # Old diesel Mercedes bleat.
	"scooter": {"freqs": [620, 740], "buzz": 0.5},    # Thin moped "meep".
}

## Engine styles: idle firing frequency (Hz) and harmonic mix. Pitch is raised
## at runtime with AudioStreamPlayer3D.pitch_scale.
const ENGINES := {
	"petrol": {"base": 40, "harmonics": [1.0, 0.5, 0.35, 0.2], "rough": 0.15},
	"diesel": {"base": 30, "harmonics": [1.0, 0.7, 0.5, 0.4, 0.3], "rough": 0.35},
	"v8": {"base": 34, "harmonics": [1.0, 0.8, 0.3, 0.45, 0.15], "rough": 0.1},
	# 2-stroke moped: high, buzzy, lots of odd harmonics. The classic sound of
	# a mobylette weaving through Casablanca traffic.
	"two_stroke": {"base": 90, "harmonics": [1.0, 0.2, 0.6, 0.15, 0.45, 0.1, 0.3], "rough": 0.25},
}

static var _cache := {}


static func horn(style: String) -> AudioStreamWAV:
	var key := "horn_" + style
	if not _cache.has(key):
		var spec: Dictionary = HORNS.get(style, HORNS["car"])
		_cache[key] = _render(func(t: float) -> float:
			var s := 0.0
			for f: int in spec["freqs"]:
				var x := sin(TAU * f * t)
				# Blend a sine with a soft-clipped (square-ish) version of itself.
				s += lerpf(x, tanh(x * 6.0), spec["buzz"])
			return s / spec["freqs"].size() * 0.8)
	return _cache[key]


static func engine(style: String) -> AudioStreamWAV:
	var key := "engine_" + style
	if not _cache.has(key):
		var spec: Dictionary = ENGINES.get(style, ENGINES["petrol"])
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(style)
		var base: int = spec["base"]
		var harmonics: Array = spec["harmonics"]
		# Pre-roll one second of slow random "lumpiness" so the engine doesn't
		# sound like a pure organ tone.
		var lumps := PackedFloat32Array()
		for i in base:
			lumps.append(1.0 + rng.randf_range(-1.0, 1.0) * spec["rough"])
		_cache[key] = _render(func(t: float) -> float:
			var s := 0.0
			for h in harmonics.size():
				s += sin(TAU * base * (h + 1) * t) * harmonics[h]
			var firing := lumps[int(t * base) % base]
			return tanh(s * 0.9 * firing) * 0.7)
	return _cache[key]


## Police siren: the two-tone "pin-pon" of French and Moroccan police, half a
## second on each note.
static func siren() -> AudioStreamWAV:
	if not _cache.has("siren"):
		_cache["siren"] = _render(func(t: float) -> float:
			var f := 650.0 if t < 0.5 else 870.0
			var x := sin(TAU * f * t)
			return lerpf(x, tanh(x * 4.0), 0.5) * 0.8)
	return _cache["siren"]


## Renders one second of `wave(t)` (t in seconds, output -1..1) into a looping
## 16-bit mono WAV.
static func _render(wave: Callable) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(MIX_RATE * 2)
	for i in MIX_RATE:
		var v := clampf(wave.call(float(i) / MIX_RATE), -1.0, 1.0)
		data.encode_s16(i * 2, int(v * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = MIX_RATE
	return wav
