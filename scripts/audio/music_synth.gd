class_name MusicSynth
extends RefCounted
## Placeholder North African music, synthesised in code for the car radio.
##
## These are stand-ins so the radio works out of the box, not real songs. Drop
## real tracks into assets/audio/radio/<station id>/ and the radio plays those
## instead (see RadioSystem).
##
## Instruments are simple but recognisable:
##   plucked strings (oud, guembri, qanun) via Karplus-Strong,
##   a bowed lead (violin/kamanja) with vibrato, a breathy ney flute,
##   darbuka (doum / tak), bendir frame drum, qraqeb metal castanets,
##   and for raï, a drum machine with synth pad and bass.
## Melodies walk the scale of each style (Hijaz for chaabi, minor pentatonic
## for gnawa, Phrygian-like modes for Andalusi, harmonic minor for raï) in
## repeated motifs with ornaments.
##
## Rendering a track takes about a second of CPU: call from a worker thread.

const RATE := 16000

## Semitones from the tonic for each style's scale.
const SCALES := {
	"chaabi": [0, 1, 4, 5, 7, 8, 10, 12],        # Hijaz: D Eb F# G A Bb C D
	"gnawa": [0, 3, 5, 7, 10, 12],               # Minor pentatonic
	"andalous": [0, 1, 3, 5, 7, 8, 10, 12],      # Phrygian (close to Kurd/Bayati)
	"rai": [0, 2, 3, 5, 7, 8, 11, 12],           # Harmonic minor
}

var _buf := PackedFloat32Array()
var _rng := RandomNumberGenerator.new()


## Renders one track in `style` (chaabi, gnawa, andalous, rai) of about
## `seconds` length. The same seed always gives the same track.
static func track(style: String, seed: int, seconds := 26.0) -> AudioStreamWAV:
	var m := MusicSynth.new()
	m._rng.seed = seed
	m._buf.resize(int((seconds + 2.0) * RATE))
	match style:
		"chaabi": m._chaabi(seconds)
		"gnawa": m._gnawa(seconds)
		"andalous": m._andalous(seconds)
		_: m._rai(seconds)
	return m._to_wav()


## Short station ident: a rising three-note chime.
static func jingle(seed: int) -> AudioStreamWAV:
	var m := MusicSynth.new()
	m._rng.seed = seed
	m._buf.resize(int(2.2 * RATE))
	var base := 392.0 * pow(2.0, (seed % 5) / 12.0)
	for k in 3:
		m._pluck(0.12 + k * 0.22, base * pow(2.0, [0, 4, 7][k] / 12.0), 1.3, 0.5, 0.9)
		m._pluck(0.12 + k * 0.22, base * 2.0 * pow(2.0, [0, 4, 7][k] / 12.0), 1.0, 0.25, 0.95)
	return m._to_wav()


# --- Styles ---------------------------------------------------------------------

## Chaabi: brisk 6/8 with darbuka and claps, bowed lead in Hijaz, oud bass.
func _chaabi(seconds: float) -> void:
	var bpm := _rng.randf_range(132.0, 150.0)
	var step := 60.0 / bpm / 2.0                   # Eighth notes, 6 per bar.
	var tonic := 146.83 * pow(2.0, _rng.randi_range(-2, 2) / 12.0)   # ~D3
	var bars := int(seconds / (step * 6.0))
	var motif := _motif(8, SCALES["chaabi"].size())
	for bar in bars:
		var t0 := bar * step * 6.0
		# Darbuka: DOUM . tak tak DOUM tak, claps on 3 and 6.
		var pattern := "D.TTDT"
		for s in 6:
			var t := t0 + s * step
			match pattern[s]:
				"D": _doum(t, 0.9)
				"T": _tak(t, 0.45)
			if s == 2 or s == 5:
				_clap(t, 0.25)
		# Oud bass on the tonic and fifth.
		_pluck(t0, tonic * 0.5, 0.9, 0.6, 0.6)
		_pluck(t0 + step * 3, tonic * 0.5 * (1.5 if bar % 2 else 1.0), 0.9, 0.5, 0.6)
		# Bowed lead: the motif, varied every other bar, with grace notes.
		for k in 3:
			var deg: int = motif[(bar * 3 + k) % motif.size()]
			if bar % 4 == 3 and k == 2:
				deg = 0                                # Resolve to the tonic.
			var f := _note(tonic * 2.0, "chaabi", deg)
			if _rng.randf() < 0.3:
				_bowed(t0 + k * step * 2 - 0.05, f * pow(2.0, 1.0 / 12.0), 0.06, 0.25)
			_bowed(t0 + k * step * 2, f, step * 1.9, 0.38)


## Gnawa: hypnotic guembri ostinato, qraqeb triplets, handclaps, call melody.
func _gnawa(seconds: float) -> void:
	var bpm := _rng.randf_range(100.0, 118.0)
	var beat := 60.0 / bpm
	var tonic := 55.0 * pow(2.0, _rng.randi_range(0, 4) / 12.0)      # ~A1
	var riff := [0, 0, 3, 0, 4, 3, 1, 0]                               # Scale degrees.
	var bars := int(seconds / (beat * 4.0))
	for bar in bars:
		var t0 := bar * beat * 4.0
		for b in 4:
			var t := t0 + b * beat
			# Qraqeb: swung triplet "tk-tk-TK".
			_qraqeb(t, 0.5)
			_qraqeb(t + beat * 0.33, 0.25)
			_qraqeb(t + beat * 0.66, 0.35)
			if b % 2 == 1:
				_clap(t, 0.3)
			# Guembri: deep, buzzy plucks following the riff.
			var deg: int = riff[(bar * 4 + b) % riff.size()]
			_pluck(t, _note(tonic, "gnawa", deg), 0.7, 0.9, 0.35, true)
			if b == 3:
				_pluck(t + beat * 0.5, _note(tonic, "gnawa", riff[(bar + 3) % riff.size()]), 0.5, 0.6, 0.35, true)
		# Call melody every other bar, sung by a reedy lead.
		if bar % 2 == 1:
			for k in 3:
				var f := _note(tonic * 4.0, "gnawa", _rng.randi_range(0, 4))
				_bowed(t0 + k * beat * 1.2, f, beat * 1.0, 0.18)


## Andalusi: stately 4/4, oud and qanun arpeggios, ney flute line.
func _andalous(seconds: float) -> void:
	var bpm := _rng.randf_range(78.0, 92.0)
	var beat := 60.0 / bpm
	var tonic := 146.83 * pow(2.0, _rng.randi_range(-2, 2) / 12.0)
	var bars := int(seconds / (beat * 4.0))
	var motif := _motif(8, SCALES["andalous"].size())
	for bar in bars:
		var t0 := bar * beat * 4.0
		var pattern := "D.T.DDT."
		for s in 8:
			match pattern[s]:
				"D": _doum(t0 + s * beat * 0.5, 0.5)
				"T": _tak(t0 + s * beat * 0.5, 0.25)
		# Qanun: quick rising arpeggio at the bar start.
		for k in 4:
			_pluck(t0 + k * 0.07, _note(tonic * 2.0, "andalous", [0, 2, 4, 7][k]), 1.2, 0.25, 0.92)
		# Oud: melody in plucked eighths.
		for k in 4:
			var deg: int = motif[(bar * 4 + k) % motif.size()]
			_pluck(t0 + k * beat, _note(tonic, "andalous", deg), 1.0, 0.55, 0.75)
		# Ney: long breathy notes on alternate bars.
		if bar % 2 == 0:
			_ney(t0, _note(tonic * 2.0, "andalous", motif[bar % motif.size()]), beat * 3.5, 0.3)


## Raï: 4/4 drum machine, minor-key pad and bass, ornamented synth lead.
func _rai(seconds: float) -> void:
	var bpm := _rng.randf_range(96.0, 108.0)
	var sixteenth := 60.0 / bpm / 4.0
	var tonic := 110.0 * pow(2.0, _rng.randi_range(-2, 2) / 12.0)     # ~A2
	var chords := [0, 7, 5, 4]                                           # i - v - iv - V (A, E, D... )
	var bars := int(seconds / (sixteenth * 16.0))
	var motif := _motif(8, SCALES["rai"].size())
	for bar in bars:
		var t0 := bar * sixteenth * 16.0
		var root: int = chords[bar % chords.size()]
		for s in 16:
			var t := t0 + s * sixteenth
			if s in [0, 6, 8, 11]:
				_kick(t, 0.8)
			if s in [4, 12]:
				_clap(t, 0.45)
			if s % 2 == 1:
				_hat(t, 0.12)
			if s % 4 == 0:
				_pluck(t, tonic * 0.5 * pow(2.0, root / 12.0), 0.35, 0.55, 0.3)
		# Pad: root + third + fifth, held through the bar.
		for iv in [0, 3, 7]:
			_pad(t0, tonic * 2.0 * pow(2.0, (root + iv) / 12.0), sixteenth * 16.0, 0.06)
		# Lead.
		for k in 4:
			var deg: int = motif[(bar * 4 + k) % motif.size()]
			_bowed(t0 + k * sixteenth * 4.0, _note(tonic * 4.0, "rai", deg), sixteenth * 3.5, 0.16)


# --- Building blocks ----------------------------------------------------------------

## A singable motif: a random walk over scale degrees, ending on a step.
func _motif(length: int, degrees: int) -> Array:
	var out := []
	var d := _rng.randi_range(2, 4)
	for i in length:
		d = clampi(d + [-2, -1, -1, 0, 1, 1, 2][_rng.randi() % 7], 0, degrees - 1)
		out.append(d)
	return out


func _note(tonic: float, style: String, degree: int) -> float:
	var scale: Array = SCALES[style]
	var octave := floori(float(degree) / scale.size())
	var semis: int = scale[posmod(degree, scale.size())]
	return tonic * pow(2.0, octave + semis / 12.0)


## Karplus-Strong plucked string. `damping` near 1 rings longer and brighter;
## `buzz` adds the guembri's rattle.
func _pluck(t: float, freq: float, dur: float, amp: float, damping: float, buzz := false) -> void:
	var start := int(t * RATE)
	var period := maxi(2, int(RATE / freq))
	var ring := PackedFloat32Array()
	ring.resize(period)
	for i in period:
		ring[i] = _rng.randf_range(-1.0, 1.0)
	var n := int(dur * RATE)
	var idx := 0
	var blend := 0.5 * (0.9 + 0.1 * damping)
	for i in n:
		var j := start + i
		if j >= _buf.size():
			break
		var nxt := (idx + 1) % period
		var v := ring[idx]
		ring[idx] = (v * blend + ring[nxt] * (1.0 - blend)) * (0.994 + 0.005 * damping)
		idx = nxt
		var s := v * amp
		if buzz:
			s = tanh(s * 3.0) * 0.6
		_buf[j] += s * minf(1.0, (n - i) / 400.0)


## Bowed lead with slow attack and vibrato.
func _bowed(t: float, freq: float, dur: float, amp: float) -> void:
	var start := int(t * RATE)
	var n := int(dur * RATE)
	var phase := 0.0
	var lp := 0.0
	for i in n:
		var j := start + i
		if j < 0:
			continue
		if j >= _buf.size():
			break
		var u := float(i) / RATE
		phase += freq * (1.0 + 0.008 * sin(TAU * 5.5 * u)) / RATE
		var saw := fmod(phase, 1.0) * 2.0 - 1.0
		lp += 0.18 * (saw - lp)
		var env := minf(u / 0.06, 1.0) * minf((n - i) / 600.0, 1.0)
		_buf[j] += lp * env * amp


func _ney(t: float, freq: float, dur: float, amp: float) -> void:
	var start := int(t * RATE)
	var n := int(dur * RATE)
	var noise_lp := 0.0
	for i in n:
		var j := start + i
		if j >= _buf.size():
			break
		var u := float(i) / RATE
		noise_lp += 0.1 * (_rng.randf_range(-1.0, 1.0) - noise_lp)
		var tone := sin(TAU * freq * u * (1.0 + 0.005 * sin(TAU * 4.5 * u)))
		var env := minf(u / 0.25, 1.0) * minf((n - i) / 2000.0, 1.0)
		_buf[j] += (tone * 0.8 + noise_lp * 0.6) * env * amp


func _pad(t: float, freq: float, dur: float, amp: float) -> void:
	var start := int(t * RATE)
	var n := int(dur * RATE)
	for i in n:
		var j := start + i
		if j >= _buf.size():
			break
		var u := float(i) / RATE
		var s := fmod(freq * u, 1.0) + fmod(freq * 1.006 * u, 1.0) - 1.0
		var env := minf(u / 0.3, 1.0) * minf((n - i) / 3000.0, 1.0)
		_buf[j] += s * env * amp


## Darbuka "doum": deep centre stroke with a falling pitch.
func _doum(t: float, amp: float) -> void:
	_drum(t, 0.25, func(u: float) -> float:
		return sin(TAU * (95.0 + 60.0 * exp(-u * 30.0)) * u) * exp(-u * 14.0) * amp)


## Darbuka "tak": sharp rim stroke.
func _tak(t: float, amp: float) -> void:
	var lp := [0.0]
	_drum(t, 0.08, func(u: float) -> float:
		var w := _rng.randf_range(-1.0, 1.0)
		lp[0] += 0.5 * (w - lp[0])
		return ((w - lp[0]) * 0.7 + sin(TAU * 720.0 * u) * 0.5) * exp(-u * 60.0) * amp)


func _qraqeb(t: float, amp: float) -> void:
	_drum(t, 0.05, func(u: float) -> float:
		return (sin(TAU * 3200.0 * u) * 0.4 + _rng.randf_range(-1.0, 1.0)) * exp(-u * 90.0) * amp)


func _clap(t: float, amp: float) -> void:
	_drum(t, 0.12, func(u: float) -> float:
		var bursts := exp(-fmod(u, 0.011) * 400.0) if u < 0.03 else exp(-(u - 0.03) * 30.0)
		return _rng.randf_range(-1.0, 1.0) * bursts * amp)


func _kick(t: float, amp: float) -> void:
	_drum(t, 0.3, func(u: float) -> float:
		return sin(TAU * (50.0 + 100.0 * exp(-u * 40.0)) * u) * exp(-u * 9.0) * amp)


func _hat(t: float, amp: float) -> void:
	_drum(t, 0.04, func(u: float) -> float:
		return _rng.randf_range(-1.0, 1.0) * exp(-u * 120.0) * amp)


func _drum(t: float, dur: float, voice: Callable) -> void:
	var start := int(t * RATE)
	var n := int(dur * RATE)
	for i in n:
		var j := start + i
		if j >= _buf.size():
			break
		_buf[j] += voice.call(float(i) / RATE)


func _to_wav() -> AudioStreamWAV:
	var peak := 0.001
	for v in _buf:
		peak = maxf(peak, absf(v))
	var gain := 0.9 / peak
	var data := PackedByteArray()
	data.resize(_buf.size() * 2)
	for i in _buf.size():
		data.encode_s16(i * 2, int(tanh(_buf[i] * gain * 1.2) * 30000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.data = data
	return wav
