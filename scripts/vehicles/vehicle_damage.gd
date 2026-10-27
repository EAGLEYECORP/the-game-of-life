class_name VehicleDamage
extends Node
## Visual-only damage for a Vehicle: dents, dirtier paint, cracked glass,
## broken headlights and engine smoke. It never changes how the vehicle drives.
##
## Add as a child of a Vehicle. Crashes are detected from sudden changes in
## velocity (a wall stops you far faster than any brake could). The side that
## got hit is worked out from the direction of that change, and the body part
## nearest to it gets dented.

## Emitted after every hit, with the remaining condition (0..100).
signal damaged(condition: float)

## Velocity change (m/s in one physics step) that counts as a crash.
@export var impact_threshold := 3.0
## Condition lost per m/s above the threshold.
@export var damage_per_impact := 3.5
## Max rotation (radians) and inward push (m) a single part can accumulate.
@export var max_dent_angle := 0.18
@export var max_dent_depth := 0.15

## 100 = showroom, 0 = wreck.
var condition := 100.0

@onready var _vehicle: Vehicle = get_parent()
@onready var _lights: VehicleLights = _vehicle.get_node_or_null("Lights")

var _parts: Array[MeshInstance3D] = []
var _original := {}           # part -> Transform3D, for repair()
var _glass_mats := {}         # part -> StandardMaterial3D (cracked)
var _prev_velocity := Vector3.ZERO
var _prev_position := Vector3.ZERO
var _smoke: CPUParticles3D
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	var body := _vehicle.get_node("Body")
	for mesh in body.find_children("*", "MeshInstance3D", true, false):
		# The rider is a person, not bodywork.
		if mesh.get_path().get_concatenated_names().contains("Rider"):
			continue
		_parts.append(mesh)
		_original[mesh] = mesh.transform
	_smoke = _make_smoke()
	_prev_position = _vehicle.global_position


func _physics_process(_delta: float) -> void:
	var v := _vehicle.linear_velocity
	var pos := _vehicle.global_position
	var dv := v - _prev_velocity
	# A jump in position means a teleport (respawn, flip), not a crash.
	var teleported := pos.distance_to(_prev_position) > 3.0
	_prev_velocity = v
	_prev_position = pos
	if teleported or _vehicle.freeze:
		return

	# Hard landings count, but less than hitting a wall.
	dv.y *= 0.3
	var strength := dv.length()
	if strength > impact_threshold:
		_on_impact(dv, strength - impact_threshold)


func _on_impact(dv: Vector3, severity: float) -> void:
	condition = maxf(condition - severity * damage_per_impact, 0.0)
	# The hit came from the side the velocity was pushed away from.
	var hit_dir := _vehicle.global_basis.inverse() * (-dv.normalized())
	# Bigger hits crumple more of the bodywork around the impact.
	for i in clampi(1 + int(severity / 3.0), 1, 4):
		_dent_nearest_part(hit_dir, severity, i)

	if hit_dir.z > 0.6 and severity > 2.0 and _lights:
		_lights.break_headlight("left" if hit_dir.x >= 0.0 else "right")
	if severity > 4.0:
		_crack_glass()
	_update_paint()
	_update_smoke()
	damaged.emit(condition)


## Rotates and pushes in the `rank`-th closest body part (0 = closest) to
## where the hit landed.
func _dent_nearest_part(hit_dir: Vector3, severity: float, rank: int) -> void:
	if _parts.size() <= rank:
		return
	# Point on the body's rough outline in the direction of the hit.
	var aabb := _body_aabb()
	var probe := aabb.get_center() + hit_dir * aabb.size * 0.5
	var sorted := _parts.duplicate()
	sorted.sort_custom(func(a: MeshInstance3D, b: MeshInstance3D) -> bool:
		return _vehicle.to_local(a.global_position).distance_squared_to(probe) 			< _vehicle.to_local(b.global_position).distance_squared_to(probe))
	var best: MeshInstance3D = sorted[rank]

	var orig: Transform3D = _original[best]
	var amount := clampf(severity / 6.0, 0.0, 1.0)
	var t := best.transform
	t.basis = t.basis.rotated(Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-1, 1)).normalized(),
		_rng.randf_range(0.3, 1.0) * max_dent_angle * amount)
	t.origin -= hit_dir * max_dent_depth * amount
	# Never let a part drift or twist further than the limits from its original.
	var offset := t.origin - orig.origin
	if offset.length() > max_dent_depth:
		t.origin = orig.origin + offset.normalized() * max_dent_depth
	if t.basis.get_euler().distance_to(orig.basis.get_euler()) > max_dent_angle * 1.5:
		t.basis = best.transform.basis
	best.transform = t


func _body_aabb() -> AABB:
	var box := AABB()
	var first := true
	for part in _parts:
		var local_aabb := _vehicle.global_transform.affine_inverse() * part.global_transform * part.get_aabb()
		box = local_aabb if first else box.merge(local_aabb)
		first = false
	return box


## Paint gets darker and duller as the vehicle takes a beating.
func _update_paint() -> void:
	var m := _vehicle.paint_material
	if m == null:
		return
	var wear := 1.0 - condition / 100.0
	m.albedo_color = _vehicle.paint_color.lerp(Color(0.18, 0.16, 0.14), wear * 0.55)
	m.roughness = lerpf(0.3, 0.85, wear)
	m.metallic = lerpf(0.45, 0.1, wear)


func _crack_glass() -> void:
	for part in _parts:
		if not part.name.begins_with("Glass") or _glass_mats.has(part):
			continue
		var cracked := StandardMaterial3D.new()
		cracked.albedo_color = Color(0.7, 0.75, 0.78)
		cracked.roughness = 0.9
		part.material_override = cracked
		_glass_mats[part] = cracked
		return   # One window per big hit.


func _update_smoke() -> void:
	_smoke.emitting = condition < 50.0
	var heavy := condition < 20.0
	_smoke.amount = 40 if heavy else 16
	_smoke.color = Color(0.1, 0.1, 0.1, 0.8) if heavy else Color(0.75, 0.75, 0.75, 0.5)


## Engine smoke, from the "EngineSmoke" marker if the vehicle has one.
func _make_smoke() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = "Smoke"
	p.emitting = false
	p.amount = 16
	p.lifetime = 1.6
	p.local_coords = false
	p.direction = Vector3.UP
	p.spread = 25.0
	p.gravity = Vector3(0, 1.5, 0)
	p.initial_velocity_min = 0.5
	p.initial_velocity_max = 1.5
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	var quad := QuadMesh.new()
	quad.size = Vector2(0.6, 0.6)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.vertex_color_use_as_albedo = true
	quad.material = mat
	p.mesh = quad
	var marker := _vehicle.get_node_or_null("EngineSmoke") as Node3D
	if marker:
		marker.add_child(p)
	else:
		_vehicle.add_child.call_deferred(p)
	return p


## Back to showroom condition.
func repair() -> void:
	condition = 100.0
	for part in _parts:
		part.transform = _original[part]
	for part in _glass_mats:
		part.material_override = null
	_glass_mats.clear()
	if _lights:
		_lights.repair()
	_update_paint()
	_update_smoke()
