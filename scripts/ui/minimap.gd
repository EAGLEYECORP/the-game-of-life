class_name Minimap
extends Control
## Round radar in the corner, GTA style.
##
## Rotates with the camera so "up" is the way you're looking. Draws the real
## road network around the player, with:
##   - you: white arrow in the middle,
##   - vehicles you can drive: grey squares,
##   - AI traffic: small pale dots,
##   - police: flashing red/blue dots, pinned to the rim when out of range.
## The rim flashes red/blue while you're wanted.
##
## Content is drawn by a child layer that this control clips to its circle
## (CLIP_CHILDREN_AND_DRAW), so roads never spill outside the radar.

@export var radius_px := 100.0
@export var range_m := 150.0          ## World metres from centre to rim.
@export var range_at_speed := 260.0   ## Zooms out to this when driving fast.
@export var redraw_rate := 20.0       ## Redraws per second.

const BG := Color(0.06, 0.08, 0.1, 0.82)
const ROAD_MAJOR := Color(0.75, 0.75, 0.72)
const ROAD_MINOR := Color(0.5, 0.5, 0.5)
const ROAD_FOOT := Color(0.35, 0.38, 0.35, 0.7)

var player: Player
var traffic: TrafficManager
var police: PoliceManager
var wanted: WantedSystem

var _layer: Control
var _timer := 0.0
var _range := 150.0


func setup(p: Player, t: TrafficManager, pol: PoliceManager, w: WantedSystem) -> void:
	player = p
	traffic = t
	police = pol
	wanted = w


func _ready() -> void:
	custom_minimum_size = Vector2.ONE * radius_px * 2.0
	size = custom_minimum_size
	clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	_layer = Control.new()
	_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layer.draw.connect(_draw_layer)
	add_child(_layer)


func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_timer = 1.0 / redraw_rate
		_layer.queue_redraw()


## The mask (and background) the layer is clipped to.
func _draw() -> void:
	draw_circle(Vector2.ONE * radius_px, radius_px, BG)


func _draw_layer() -> void:
	if player == null:
		return
	var center := Vector2.ONE * radius_px
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	# Camera-relative axes on the ground plane.
	var f3 := -cam.global_basis.z
	var fwd := Vector2(f3.x, f3.z).normalized()
	var right := Vector2(-fwd.y, fwd.x)   # Camera right on the ground (+X when facing -Z).
	var origin := Vector2(player.global_position.x, player.global_position.z)

	# Zoom out with speed so you can see where you're going.
	var speed := player.current_vehicle.get_speed_kmh() if player.current_vehicle else 0.0
	_range = lerpf(_range, lerpf(range_m, range_at_speed, clampf(speed / 120.0, 0.0, 1.0)), 0.1)
	var scale := radius_px / _range
	var to_map := func(w: Vector2) -> Vector2:
		var r := w - origin
		return center + Vector2(r.dot(right), -r.dot(fwd)) * scale

	# Roads.
	if traffic and traffic.graph:
		var g := traffic.graph
		for e in g.edges_near(origin, _range * 1.2):
			var pts := g.edge_points[e]
			var line := PackedVector2Array()
			for p in pts:
				line.append(to_map.call(p))
			var col := ROAD_FOOT
			var width := 1.0
			if g.edge_kind[e] != RoadGraph.Kind.WALK_ONLY:
				col = ROAD_MAJOR if g.edge_class[e] >= 2 else ROAD_MINOR
				width = maxf(g.edge_width[e] * scale, 2.0)
			draw_polyline_on(line, col, width)

	# Vehicles you could take, then traffic.
	var own := player.current_vehicle
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v == own or v.is_police:
			continue
		var m: Vector2 = to_map.call(Vector2(v.global_position.x, v.global_position.z))
		if m.distance_to(center) < radius_px:
			_layer.draw_rect(Rect2(m - Vector2(2.5, 2.5), Vector2(5, 5)), Color(0.7, 0.7, 0.7))
	for c in get_tree().get_nodes_in_group("traffic_cars"):
		var m: Vector2 = to_map.call(Vector2(c.global_position.x, c.global_position.z))
		if m.distance_to(center) < radius_px:
			_layer.draw_circle(m, 1.8, Color(0.85, 0.85, 0.75, 0.8))

	# Police: flashing, clamped to the rim when outside the radar.
	var blink := fmod(Time.get_ticks_msec() * 0.001, 0.5) < 0.25
	if police:
		for p3 in police.unit_positions():
			var m: Vector2 = to_map.call(Vector2(p3.x, p3.z))
			var off := m - center
			if off.length() > radius_px - 6.0:
				m = center + off.normalized() * (radius_px - 6.0)
			_layer.draw_circle(m, 4.5, Color(1, 0.15, 0.1) if blink else Color(0.2, 0.4, 1))
			_layer.draw_arc(m, 4.5, 0, TAU, 12, Color.WHITE, 1.0)

	# The player: an arrow pointing where they're heading.
	var yaw := own.global_rotation.y if own else player.get_facing_yaw()
	var h3 := Vector2(sin(yaw), cos(yaw))
	var h := Vector2(h3.dot(right), -h3.dot(fwd)).normalized()
	var side := Vector2(-h.y, h.x)
	_layer.draw_colored_polygon(PackedVector2Array([center + h * 8.0, center - h * 5.0 + side * 5.0,
		center - h * 2.5, center - h * 5.0 - side * 5.0]), Color.WHITE)

	# North marker on the rim.
	var north := Vector2(Vector2(0, -1).dot(right), -Vector2(0, -1).dot(fwd)).normalized()
	var npos := center + north * (radius_px - 11.0)
	_layer.draw_circle(npos, 7.0, Color(0, 0, 0, 0.6))
	_layer.draw_string(get_theme_default_font(), npos + Vector2(-4, 4), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 11)

	# Rim: flashes police colours while wanted.
	var rim := Color(0.9, 0.9, 0.9, 0.7)
	if wanted and wanted.stars > 0:
		rim = Color(1, 0.2, 0.15) if blink else Color(0.25, 0.45, 1)
	_layer.draw_arc(center, radius_px - 1.5, 0, TAU, 64, rim, 3.0, true)


func draw_polyline_on(line: PackedVector2Array, col: Color, width: float) -> void:
	if line.size() >= 2:
		_layer.draw_polyline(line, col, width, true)
