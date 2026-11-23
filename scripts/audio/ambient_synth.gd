class_name AmbientSynth
extends RefCounted
## Generates the city's background sounds in code: Atlantic surf, traffic
## rumble, city murmur and seagulls. Loops are rendered slightly long and the
## tail is crossfaded into the head, so they repeat without a seam.
##
## Rendering takes a moment, so call these from a worker thread (AmbientAudio
## does) and cache the result.

const RATE := 16000


## Waves rolling in and breaking: brown-noise swells with brighter foam.
static func ocean(seconds := 8.0) -> AudioStreamWAV:
	var rng := _rng(11)
	var n := int(seconds * RATE)
	var buf := PackedFloat32Array()
	buf.resize(n + RATE / 2)
	var brown := 0.0
	var low := 0.0
	var high_prev := 0.0
	for i in buf.size():
		var t := float(i % n) / RATE
		var white := rng.randf_range(-1.0, 1.0)
		brown = clampf(brown * 0.995 + white * 0.05, -1.0, 1.0)
		low += 0.08 * (brown - low)
		var foam := white - high_prev     # Crude high-pass for the hiss.
		high_prev = white
		# Two waves per loop: slow build, crash, long wash back.
		var phase := fmod(t / seconds * 2.0, 1.0)
		var swell := pow(sin(phase * PI), 2.0)
		var crash := exp(-pow((phase - 0.45) * 7.0, 2.0))
		buf[i] = low * (0.5 + 0.6 * swell) * 2.2 + foam * 0.08 * (0.2 + crash)
	return _finish(buf, n)


## Distant traffic: engine drone, tyre rumble and the odd far-off horn.
static func traffic(seconds := 6.0) -> AudioStreamWAV:
	var rng := _rng(23)
	var n := int(seconds * RATE)
	var buf := PackedFloat32Array()
	buf.resize(n + RATE / 2)
	var brown := 0.0
	var low := 0.0
	var horns := [[rng.randf_range(0.5, 2.5), 420.0], [rng.randf_range(3.2, 5.0), 360.0]]
	for i in buf.size():
		var t := float(i % n) / RATE
		brown = clampf(brown * 0.997 + rng.randf_range(-1.0, 1.0) * 0.04, -1.0, 1.0)
		low += 0.03 * (brown - low)
		var drone := sin(TAU * 55.0 * t + sin(TAU * 0.3 * t) * 2.0) * 0.12
		var s := low * 3.0 + drone
		for h in horns:
			var dt: float = t - h[0]
			if dt > 0.0 and dt < 0.35:
				s += tanh(sin(TAU * h[1] * t) * 3.0) * 0.06 * sin(dt / 0.35 * PI)
		buf[i] = s
	return _finish(buf, n)


## City murmur: crowd hum, a moped buzzing past, a door, distant voices.
static func city(seconds := 8.0) -> AudioStreamWAV:
	var rng := _rng(37)
	var n := int(seconds * RATE)
	var buf := PackedFloat32Array()
	buf.resize(n + RATE / 2)
	var band_lo := 0.0
	var band_hi := 0.0
	var moped_start := rng.randf_range(1.0, 4.0)
	for i in buf.size():
		var t := float(i % n) / RATE
		var white := rng.randf_range(-1.0, 1.0)
		band_lo += 0.25 * (white - band_lo)
		band_hi += 0.04 * (band_lo - band_hi)
		var crowd := (band_lo - band_hi) * (0.6 + 0.4 * sin(TAU * 0.7 * t) * sin(TAU * 0.23 * t))
		var s := crowd * 0.5
		# Moped passing by: rising then falling two-stroke buzz.
		var mt := t - moped_start
		if mt > 0.0 and mt < 3.0:
			var pitch := 110.0 + 30.0 * sin(mt / 3.0 * PI) - mt * 8.0
			s += tanh(sin(TAU * pitch * mt) * 4.0) * 0.05 * sin(mt / 3.0 * PI)
		buf[i] = s
	return _finish(buf, n)


## One seagull call: a few raspy downward cries. Not looped.
static func gull() -> AudioStreamWAV:
	var rng := _rng(51)
	var calls := 3
	var n := int(1.6 * RATE)
	var buf := PackedFloat32Array()
	buf.resize(n)
	for c in calls:
		var start := int((0.1 + c * 0.42) * RATE)
		var length := int(0.32 * RATE)
		var phase := 0.0
		for k in length:
			var u := float(k) / length
			var f := lerpf(2100.0, 1300.0, u) + rng.randf_range(-60.0, 60.0)
			phase += TAU * f / RATE
			var env := sin(u * PI) * (1.0 - u * 0.4)
			var i := start + k
			if i < n:
				buf[i] += (sin(phase) + 0.4 * sin(phase * 2.0) + 0.15 * rng.randf_range(-1.0, 1.0)) * env * 0.35
	return _to_wav(buf, false)


# --- Helpers ----------------------------------------------------------------

static func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


## Crossfades the extra tail into the start, normalises and makes a looping WAV.
static func _finish(buf: PackedFloat32Array, n: int) -> AudioStreamWAV:
	var fade := buf.size() - n
	for i in fade:
		var t := float(i) / fade
		buf[i] = buf[i] * t + buf[n + i] * (1.0 - t)
	buf.resize(n)
	return _to_wav(buf, true)


static func _to_wav(buf: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var peak := 0.001
	for v in buf:
		peak = maxf(peak, absf(v))
	var gain := 0.85 / peak
	var data := PackedByteArray()
	data.resize(buf.size() * 2)
	for i in buf.size():
		data.encode_s16(i * 2, int(clampf(buf[i] * gain, -1.0, 1.0) * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.data = data
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = buf.size()
	return wav
