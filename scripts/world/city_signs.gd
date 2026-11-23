class_name CitySigns
extends RefCounted
## Street plates, shop signs and billboards: the text of Casablanca's streets.
##
## Moroccan street plates are bilingual (French and Arabic). Shop signs and
## billboards mix Arabic script, Darija (Moroccan Arabic) and French, the way
## they do on the real streets. All text renders with the bundled Noto Sans and
## Noto Sans Arabic fonts (SIL Open Font License, see assets/fonts/), so Arabic
## is shaped right-to-left correctly on every platform.
##
## Signs are plain Label3D + one box mesh each and vanish beyond a short
## distance, so a street full of them stays cheap.

## [Arabic / Darija, French or transliteration, panel colour, text colour]
const SHOPS := [
	["حانوت", "Hanout · Alimentation", Color(0.1, 0.35, 0.2), Color.WHITE],
	["مقهى", "Café", Color(0.35, 0.18, 0.08), Color(1.0, 0.9, 0.7)],
	["صيدلية", "Pharmacie", Color(0.05, 0.5, 0.25), Color.WHITE],
	["مخبزة", "Boulangerie", Color(0.6, 0.4, 0.15), Color.WHITE],
	["حجام", "Hajjam · Coiffeur", Color(0.12, 0.2, 0.45), Color.WHITE],
	["تيليبوتيك", "Téléboutique", Color(0.75, 0.55, 0.05), Color(0.1, 0.1, 0.1)],
	["سناك", "Snack", Color(0.7, 0.12, 0.1), Color.WHITE],
	["حمام", "Hammam", Color(0.1, 0.3, 0.5), Color.WHITE],
	["مطعم", "Restaurant", Color(0.45, 0.08, 0.1), Color(1.0, 0.85, 0.5)],
	["قهوة و أتاي", "Qahwa w Atay · Café thé", Color(0.15, 0.3, 0.3), Color.WHITE],
]

## Billboard slogans: [Darija, transliteration — meaning].
const SLOGANS := [
	["سير بشوية", "Sir b-chwiya — drive slowly"],
	["كازا كتبقى كازا", "Casa katbqa Casa — Casa stays Casa"],
	["مرحبا بيكم فكازا", "Mrehba bikom f Casa — welcome to Casa"],
	["رد بالك", "Redd balek — watch out"],
	["كولشي مزيان", "Kolchi mzyan — all good"],
	["زيد القدام", "Zid l-qeddam — keep moving"],
]

const PLATE_BLUE := Color(0.08, 0.22, 0.55)

static var _font: Font


## Noto Sans with Noto Sans Arabic as fallback for Arabic script.
static func font() -> Font:
	if _font == null:
		var latin: FontFile = load("res://assets/fonts/NotoSans.ttf")
		var arabic: FontFile = load("res://assets/fonts/NotoSansArabic.ttf")
		var f := FontVariation.new()
		f.base_font = latin
		f.fallbacks = [arabic]
		_font = f
	return _font


## A shop sign on a facade: coloured panel, Arabic name above, French below.
## `normal` points out of the wall.
static func shop_sign(parent: Node3D, pos: Vector3, normal: Vector3, width: float, seed: int) -> void:
	var shop: Array = SHOPS[seed % SHOPS.size()]
	var root := Node3D.new()
	parent.add_child(root)
	root.position = pos + normal * 0.08
	root.basis = Basis.looking_at(-normal, Vector3.UP)     # Label front faces the street.
	_panel(root, Vector3(width, 0.9, 0.08), shop[2], Vector3.ZERO)
	_label(root, shop[0], 64, shop[3], Vector3(0, 0.16, 0.05))
	_label(root, shop[1], 34, shop[3], Vector3(0, -0.22, 0.05))


## Street name plate on a pole at a junction corner. `facing` is the yaw of
## the plate's front; both faces are readable.
static func street_plate(parent: Node3D, pos: Vector3, facing: float, french: String, arabic: String) -> void:
	var root := Node3D.new()
	parent.add_child(root)
	root.position = pos
	root.rotation.y = facing
	_panel(root, Vector3(0.06, 2.6, 0.06), Color(0.35, 0.36, 0.38), Vector3(0, 1.3, 0))
	var width := clampf(maxi(french.length(), arabic.length()) * 0.085, 1.0, 2.6)
	_panel(root, Vector3(width, 0.52, 0.04), PLATE_BLUE, Vector3(0, 2.75, 0))
	_panel(root, Vector3(width + 0.06, 0.58, 0.035), Color.WHITE, Vector3(0, 2.75, 0))   # Border.
	for side in [1.0, -1.0]:
		var face := Node3D.new()
		root.add_child(face)
		face.position = Vector3(0, 2.75, 0.026 * side)
		face.rotation.y = 0.0 if side > 0.0 else PI
		_label(face, french, 30, Color.WHITE, Vector3(0, 0.1, 0))
		if arabic != "":
			_label(face, arabic, 34, Color.WHITE, Vector3(0, -0.12, 0))


## Roadside billboard on two legs with a Darija slogan.
static func billboard(parent: Node3D, pos: Vector3, facing: float, seed: int) -> void:
	var slogan: Array = SLOGANS[seed % SLOGANS.size()]
	var root := Node3D.new()
	parent.add_child(root)
	root.position = pos
	root.rotation.y = facing
	for x in [-1.6, 1.6]:
		_panel(root, Vector3(0.15, 3.0, 0.15), Color(0.3, 0.3, 0.32), Vector3(x, 1.5, 0))
	var bg: Color = [Color(0.95, 0.85, 0.2), Color(0.85, 0.15, 0.12), Color(0.1, 0.45, 0.65), Color(0.95, 0.95, 0.92)][seed % 4]
	var fg := Color(0.1, 0.1, 0.1) if bg.get_luminance() > 0.5 else Color.WHITE
	_panel(root, Vector3(4.6, 2.2, 0.15), bg, Vector3(0, 4.0, 0))
	_label(root, slogan[0], 120, fg, Vector3(0, 4.35, 0.09), 90.0)
	_label(root, slogan[1], 40, fg, Vector3(0, 3.45, 0.09), 90.0)


# --- Helpers --------------------------------------------------------------------

static var _materials := {}


static func _panel(parent: Node3D, size: Vector3, color: Color, pos: Vector3) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var key := color.to_html()
	if not _materials.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.6
		_materials[key] = m
	mesh.material = _materials[key]
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.visibility_range_end = 110.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


static func _label(parent: Node3D, text: String, size: int, color: Color, pos: Vector3, fade := 60.0) -> void:
	var l := Label3D.new()
	l.text = text
	l.font = font()
	l.font_size = size
	l.pixel_size = 0.005
	l.modulate = color
	l.outline_size = 0
	l.double_sided = false
	l.position = pos
	l.visibility_range_end = fade
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(l)
