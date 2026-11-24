class_name MissionNpc
extends Node3D
## A scripted person for missions: taxi passengers, contacts waiting at a
## marker. Uses the same cheap model as the street pedestrians and can walk
## to a point (e.g. a car door) and then vanish ("gets in").

signal arrived

var _model: Node3D
var _limbs: Dictionary
var _target := Vector3.INF
var _speed := 1.6
var _phase := 0.0
var _wave := false


static func create(parent: Node, pos: Vector3, seed: int) -> MissionNpc:
	var npc := MissionNpc.new()
	parent.add_child(npc)
	npc.global_position = pos
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	npc._model = Node3D.new()
	npc.add_child(npc._model)
	npc._limbs = NpcVisuals.build_pedestrian(npc._model, rng)
	return npc


## Arm up, flagging down a taxi.
func set_waving(on: bool) -> void:
	_wave = on


func walk_to(pos: Vector3, speed := 1.6) -> void:
	_target = pos
	_speed = speed


func face(pos: Vector3) -> void:
	var d := pos - global_position
	if Vector2(d.x, d.z).length() > 0.1:
		rotation.y = atan2(d.x, d.z)


func _process(delta: float) -> void:
	var moving := false
	if _target != Vector3.INF:
		var d := _target - global_position
		d.y = 0.0
		if d.length() < 0.3:
			_target = Vector3.INF
			arrived.emit()
		else:
			global_position += d.normalized() * minf(_speed * delta, d.length())
			rotation.y = atan2(d.x, d.z)
			moving = true
	# Simple walk cycle / waving arm.
	_phase += delta * (_speed * 4.5 if moving else 0.0)
	var swing := sin(_phase) * (0.5 if moving else 0.0)
	_limbs["legs"][0].rotation.x = swing
	_limbs["legs"][1].rotation.x = -swing
	_limbs["arms"][1].rotation.x = swing * 0.8
	_limbs["arms"][0].rotation.x = -2.6 + sin(Time.get_ticks_msec() * 0.008) * 0.3 if _wave else -swing * 0.8
