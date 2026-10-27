class_name WantedStars
extends Control
## The five wanted stars, drawn as polygons (no font needed). Earned stars are
## gold; they flash while the police have lost sight of you and are searching.

@export var star_radius := 15.0
@export var spacing := 36.0

var stars := 0
var searching := false


func _ready() -> void:
	custom_minimum_size = Vector2(spacing * 5.0, star_radius * 2.4)


func set_stars(n: int) -> void:
	stars = n
	queue_redraw()


func set_seen(seen: bool) -> void:
	searching = not seen
	queue_redraw()


func _process(_delta: float) -> void:
	if stars > 0 and searching:
		queue_redraw()   # Animate the flashing.


func _draw() -> void:
	var flash_off := searching and stars > 0 and fmod(Time.get_ticks_msec() * 0.001, 0.6) < 0.3
	for i in 5:
		# Stars fill from the right, like GTA.
		var lit := (4 - i) < stars
		var c := Vector2(spacing * (i + 0.5), star_radius * 1.2)
		var pts := _star(c, star_radius, star_radius * 0.45)
		var outline := pts.duplicate()
		outline.append(pts[0])
		if lit and not flash_off:
			draw_colored_polygon(pts, Color(1, 0.82, 0.25))
			draw_polyline(outline, Color(0.2, 0.12, 0), 2.0, true)
		else:
			draw_colored_polygon(pts, Color(0, 0, 0, 0.35))
			draw_polyline(outline, Color(1, 1, 1, 0.45), 1.5, true)


func _star(c: Vector2, r_out: float, r_in: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 10:
		var r := r_out if k % 2 == 0 else r_in
		var a := -PI * 0.5 + k * PI / 5.0
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts
